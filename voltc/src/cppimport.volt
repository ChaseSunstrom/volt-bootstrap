// C++ import: `use cpp { "shapes.hpp" } as shapes;` reads C++ headers with libclang and turns what
// Volt can use into Volt source, declared in namespace `shapes`:
//   namespaces      -> namespaces
//   classes         -> structs with C++'s layout: public fields where C++ puts them, the rest padding;
//                      one that isn't trivially copyable (clang says) is a handle to an object C++
//                      allocates (new, delete), its public fields getters and set_ methods
//   constructors    -> T::new(...) (static attach fns); a class without any gets T::new()
//   destructor      -> delete; copy constructor -> copy (only for classes that need them)
//   methods         -> attach fns (static ones take `static this`); overloads stay overloads, and a
//                      default argument gives an overload without it
//   free functions  -> fns; function and class templates -> generic fns and structs
//   enums           -> enums with the same tag type and values (an unscoped one's names are also
//                      constants next to it)
//   operators       -> op_ methods and fns (operator+ is op_add, operator[] op_index...)
//   std::string, std::string_view -> str in, std::string (a copy) or str out; std::vector<T> ->
//                      T[..] in, std::vec<T> (a copy) out; std::unique_ptr, std::shared_ptr ->
//                      stdcxx::unique_ptr<T>, stdcxx::shared_ptr<T>; T&& -> T, moved in
// Every body is one @cpp<R>("C++ expression", args) (calls.volt): the checker turns each call it
// instantiates into an extern "C" wrapper function in a C++ file compiled with $CXX and linked in,
// so both backends call C++ the same way. A C++ exception that reaches one stops the program; a
// function that can throw also gets a try_ form that returns a cpp_error naming the exception
// instead (its message: last_exception()). What doesn't map is left out with a comment.
use { "clang-c/Index.h" } as clang;
use std::mem;
use std::fmt;

// what clang says of an imported class (see probe)
struct cpp_traits {
    trivial: bool = false;      // trivially copyable: Volt holds it by value, else by handle
    destructible: bool = false; // its destructor can be called from outside, so Volt can own one
    copyable: bool = false;     // it can be made from a const& (it isn't abstract, its copy constructor is public)
    movable: bool = false;      // it can be made from a && (moved, or copied)
    defaults: bool = false;     // it can be made from nothing (T::new() when it declares no constructor)
    polymorphic: bool = false;  // it has virtual methods
    final_: bool = false;       // it's final: nothing derives from it
    vdtor: bool = false;        // its destructor is virtual (deleting a subclass through it is right)
    exception: bool = false;    // it derives from std::exception (a try_ form's error names it)
    assignable: bool = false;   // it can be assigned from an rvalue (a field of it gets a set_)
}

// the Volt source being written for one import: the classes, enums and class templates it declares
// (C++ qualified name -> Volt path inside the import's namespace), so types can refer to them
struct cpp_gen {
    c: checker&;
    out: std::string = {};
    note: std::string = {}; // the C++ declaration the next fn wraps, as a comment above it (hover shows it)
    classes: std::map<str, str> = {};
    enums: std::map<str, str> = {};
    templates: std::map<str, str> = {};
    depth: usize = 0;
    // the C++ namespace being written, and the Volt signatures written in it (an overload and a
    // default argument can give the same one: it's written once)
    scope: std::string = {};
    written: std::map<str, bool> = {};
    // the std class templates a signature used, which stdcxx declares
    unique: bool = false;
    shared: bool = false;
    // a try_ form was written (so cpp_error and last_exception are needed)
    tries: bool = false;
    // what clang says of each class (C++ qualified names): one that isn't trivially copyable Volt
    // holds by handle
    traits: std::map<str, cpp_traits> = {};
    // each class's cursor (C++ qualified names)
    cursors: std::map<str, clang::CXCursor> = {};
    // the C++ function telling which exception a try_ form caught (volt_cpp_kinds_N, one an import)
    kinds: std::string = {};
    // the functions written so far, by USR (a function declared, then defined, is one: its
    // template parameters may be named differently each time)
    fns_seen: std::map<str, bool> = {};
    // where the libraries the use names live, as found on the include path ("/usr/include/re2/" for
    // re2/re2.h, the file itself for a header with no directory): their declarations are the
    // import's own though the C++ compiler sees them as system headers
    roots: std::vec<std::string> = {};
    // the std::function signatures results come back as (stdcxx::function's call overloads), by
    // their C++ type (int(int))
    fn_sigs: std::map<str, clang::CXType> = {};
    // the class template whose members are being written: its generic list (a member called per
    // use keeps it, for its receiver's type)
    class_gen: std::string = {};
}

// ---------- names ----------

fn in_system(c: clang::CXCursor) -> bool {
    return clang::clang_Location_isInSystemHeader(clang::clang_getCursorLocation(c)) != 0;
}

// is c none of the import's own: in a system header, and not in a library one of the use names
// (see roots)
attach fn skip(this: cpp_gen&, c: clang::CXCursor) -> bool {
    // an explicit specialization (template <> struct S<void>, template <> bool f<int>(...)) has
    // the template's name: the template is what Volt sees
    if (clang::clang_Cursor_isNull(clang::clang_getSpecializedCursorTemplate(c)) == 0) {
        return true;
    }
    // a member defined outside its class (template <...> vec<2, T, Q>::vec(...) at namespace
    // scope) is the class's, not a free function
    val k = clang::clang_getCursorKind(c);
    if (k == clang::CXCursor_FunctionDecl || k == clang::CXCursor_FunctionTemplate) {
        val pk = clang::clang_getCursorKind(clang::clang_getCursorSemanticParent(c));
        if (pk == clang::CXCursor_ClassDecl || pk == clang::CXCursor_StructDecl || pk == clang::CXCursor_ClassTemplate || pk == clang::CXCursor_ClassTemplatePartialSpecialization) {
            return true;
        }
    }
    // what a library adds to namespace std (std::hash<T>, std::swap overloads) isn't its own API,
    // and a Volt namespace std in the import would hide Volt's
    if (clang::clang_getCursorKind(c) == clang::CXCursor_Namespace && cursor_name(c).as_str() == "std") {
        return true;
    }
    if (!in_system(c)) {
        return false;
    }
    if (this.roots.len == 0) {
        return true;
    }
    val f = cursor_file(c);
    for (r&) in this.roots.items() {
        // a directory's files, or the one file
        if ((ends_with(r.as_str(), "/") && starts_with(f.as_str(), r.as_str())) || f.as_str() == r.as_str()) {
            return false;
        }
    }
    return true;
}

// the C++ qualified name of a declaration: geo::Shape
fn cpp_qual(c: clang::CXCursor) -> std::string {
    var parts: std::vec<std::string> = {};
    var cur = c;
    loop {
        val k = clang::clang_getCursorKind(cur);
        if (k == clang::CXCursor_TranslationUnit || clang::clang_Cursor_isNull(cur) != 0) {
            break;
        }
        put(&parts, cursor_name(cur));
        cur = clang::clang_getCursorSemanticParent(cur);
    }
    var out: std::string = {};
    var i = parts.len;
    while (i > 0) {
        i -= 1;
        if (parts.at(i).len() == 0) {
            continue;
        }
        if (out.len() > 0) {
            out.append("::");
        }
        out.append(parts.at(i).as_str());
    }
    return out;
}

// the name of the standard library class template t is an instance of (basic_string, vector,
// unique_ptr...; inline namespaces like std::__cxx11 skipped), or none
fn std_template(t: clang::CXType) -> std::string? {
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind != clang::CXType_Record) {
        return null;
    }
    val tmpl = clang::clang_getSpecializedCursorTemplate(clang::clang_getTypeDeclaration(ct));
    if (clang::clang_Cursor_isNull(tmpl) != 0) {
        return null;
    }
    var ns = clang::clang_getCursorSemanticParent(tmpl);
    while (clang::clang_getCursorKind(ns) == clang::CXCursor_Namespace && clang::clang_Cursor_isInlineNamespace(ns) != 0) {
        ns = clang::clang_getCursorSemanticParent(ns);
    }
    if (clang::clang_getCursorKind(ns) != clang::CXCursor_Namespace || cursor_name(ns).as_str() != "std") {
        return null;
    }
    if (clang::clang_getCursorKind(clang::clang_getCursorSemanticParent(ns)) != clang::CXCursor_TranslationUnit) {
        return null;
    }
    return cursor_name(tmpl);
}

// is t a std::string or std::string_view (of char)?
fn char_text(t: clang::CXType, which: str) -> bool {
    val st = std_template(t) ?? return false;
    if (st.as_str() != which) {
        return false;
    }
    val k = clang::clang_getCanonicalType(clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(t), 0)).kind;
    return k == clang::CXType_Char_S || k == clang::CXType_Char_U;
}

// a C++ name Volt can declare (keywords get a _)
fn vname(n: str) -> std::string {
    var out = S(n);
    if (is_keyword(n) || n == "this" || n == "new" || n == "delete" || n == "copy") {
        out.push('_');
    }
    return out;
}

attach fn line(this: cpp_gen&, text: str) -> void {
    push_n(&this.out, ' ', this.depth * 4);
    this.out.append(text);
    this.out.push('\n');
}

// ---------- types ----------

fn strip_const(s: str) -> str {
    if (starts_with(s, "const ")) {
        return s[6..s.len];
    }
    return s;
}

// the Volt type of a C++ type, or none; tparams are the enclosing template's type parameters
attach fn vtype(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> std::string? {
    val sp = type_spelling(t);
    for (p&) in tparams.items() {
        if (strip_const(sp.as_str()) == *p) {
            return S(*p);
        }
    }
    val ct = clang::clang_getCanonicalType(t);
    val k = ct.kind;
    if (k == clang::CXType_Void) {
        return S("void");
    }
    if (k == clang::CXType_Bool) {
        return S("bool");
    }
    if (k == clang::CXType_Char_S || k == clang::CXType_SChar) {
        return S("i8");
    }
    if (k == clang::CXType_Char_U || k == clang::CXType_UChar) {
        return S("u8");
    }
    if (k == clang::CXType_Short) {
        return S("i16");
    }
    if (k == clang::CXType_UShort) {
        return S("u16");
    }
    if (k == clang::CXType_Int) {
        return S("i32");
    }
    if (k == clang::CXType_UInt) {
        return S("u32");
    }
    if (k == clang::CXType_Long || k == clang::CXType_LongLong) {
        return S("i64");
    }
    if (k == clang::CXType_ULong || k == clang::CXType_ULongLong) {
        return S("u64");
    }
    if (k == clang::CXType_Float) {
        return S("f32");
    }
    if (k == clang::CXType_Double) {
        return S("f64");
    }
    if (k == clang::CXType_Pointer) {
        // the pointee as written (a template's T* is T* by its name), else the canonical one's
        var pt = clang::clang_getPointeeType(t);
        if (pt.kind == clang::CXType_Invalid) {
            pt = clang::clang_getPointeeType(ct);
        }
        val pk = clang::clang_getCanonicalType(pt).kind;
        if (pk == clang::CXType_Char_S || pk == clang::CXType_SChar) {
            return S("cstr?");
        }
        if (pk == clang::CXType_Void) {
            return S("void*");
        }
        // a pointer to an object Volt holds by handle has no Volt form
        if (this.handle_of(pt) != null) {
            return null;
        }
        var inner = this.vtype(pt, tparams) ?? return null;
        inner.push('*');
        return inner;
    }
    if (k == clang::CXType_Record) {
        return this.record(ct, tparams);
    }
    if (k == clang::CXType_Enum) {
        val q = cpp_qual(clang::clang_getTypeDeclaration(ct));
        val e = this.enums.get(q.as_str()) ?? return null;
        return S(*e);
    }
    return null;
}

// an imported class (geo::Shape), or an instance of an imported class template (geo::Box<i32>)
attach fn record(this: cpp_gen&, ct: clang::CXType, tparams: std::vec<str>&) -> std::string? {
    val st = std_template(ct);
    if (st) {
        // std::unique_ptr<T> (its default deleter: one pointer) and std::shared_ptr<T>
        val name = st.as_str();
        val size = clang::clang_Type_getSizeOf(ct);
        if ((name == "unique_ptr" && size == 8) || (name == "shared_ptr" && size == 16)) {
            val at = clang::clang_Type_getTemplateArgumentAsType(ct, 0);
            if (this.handle_of(at) != null) {
                return null;
            }
            val a = this.vtype(at, tparams) ?? return null;
            if (name == "unique_ptr") {
                this.unique = true;
            } else {
                this.shared = true;
            }
            return fmt2("stdcxx::{}<{}>", copy st, move a);
        }
        return null;
    }
    val decl = clang::clang_getTypeDeclaration(ct);
    val q = cpp_qual(decl);
    val c = this.classes.get(q.as_str());
    if (c) {
        return S(*c);
    }
    val n = clang::clang_Type_getNumTemplateArguments(ct);
    if (n <= 0) {
        return null;
    }
    val tq = cpp_qual(clang::clang_getSpecializedCursorTemplate(decl));
    val base = this.templates.get(tq.as_str()) ?? return null;
    // as many arguments as the Volt generic has (the defaulted rest are C++'s)
    var count = @cast<u32>(n);
    val tc = this.cursors.get(tq.as_str());
    if (tc) {
        val tps = template_params(*tc) ?? return null;
        if (@cast<u32>(tps.len) < count) {
            count = @cast<u32>(tps.len);
        }
    }
    var out = S(*base);
    out.push('<');
    for (i) in 0..count {
        if (i > 0) {
            out.append(", ");
        }
        val at = clang::clang_Type_getTemplateArgumentAsType(ct, i);
        if (this.handle_of(at) != null) {
            return null;
        }
        val a = this.vtype(at, tparams) ?? return null;
        out.append(a.as_str());
    }
    out.push('>');
    return out;
}

fn is_class(t: clang::CXType) -> bool {
    return clang::clang_getCanonicalType(t).kind == clang::CXType_Record;
}

// the C++ name of a class Volt holds by handle, when t is one
attach fn handle_of(this: cpp_gen&, t: clang::CXType) -> std::string? {
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind != clang::CXType_Record) {
        return null;
    }
    val q = cpp_qual(clang::clang_getTypeDeclaration(ct));
    val tr = this.traits.get(q.as_str()) ?? return null;
    if (tr->trivial) {
        return null;
    }
    return q;
}

// can a getter copy a value of type t out of where it is (a field, a static member): a class, held
// by value or by handle, needs a copy constructor (a trivially copyable one may have it deleted)
attach fn copies_out(this: cpp_gen&, t: clang::CXType) -> bool {
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind != clang::CXType_Record || std_template(ct) != null) {
        return true;
    }
    val tr = this.traits.get(cpp_qual(clang::clang_getTypeDeclaration(ct)).as_str()) ?? return true;
    return tr->copyable;
}

// can a field of type t be assigned what set_ passes (an rvalue of its type)? An imported class
// as clang says, a std one (std::string, std::vector, the smart pointers) yes, an instance of an
// imported class template no (it may have a const field)
attach fn assignable(this: cpp_gen&, t: clang::CXType) -> bool {
    if (clang::clang_isConstQualifiedType(t) != 0) {
        return false;
    }
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind != clang::CXType_Record) {
        return true;
    }
    val tr = this.traits.get(cpp_qual(clang::clang_getTypeDeclaration(ct)).as_str());
    if (tr != null) {
        return tr->assignable;
    }
    // a std::function set from a Volt fn value would keep the closure past the call
    val st = std_template(ct) ?? return false;
    return st.as_str() != "function";
}

// how one C++ parameter crosses: its Volt type, what the Volt fn passes to @cpp, and the C++
// expression for it ({i} is @cpp's argument i: a reference or a class arrives as the object itself)
struct cpp_arg {
    vty: std::string;
    pass: std::string;
    cpp: std::string;
}

attach fn param(this: cpp_gen&, t: clang::CXType, name: str, i: usize, tparams: std::vec<str>&) -> cpp_arg? {
    var slot = S("{");
    slot.append_uint(@cast<u64>(i));
    slot.push('}');
    val sp = type_spelling(t);
    for (p&) in tparams.items() {
        // T, const T&: by reference, so a class argument works too
        val bare = strip_const(sp.as_str());
        if (bare == *p || (ends_with(bare, "&") && strip_const(bare[0..bare.len - 1]) == *p) || (ends_with(bare, " &") && strip_const(bare[0..bare.len - 2]) == *p)) {
            return { vty: S(*p), pass: fmt("&{}", S(name)), cpp: move slot };
        }
    }
    val k = t.kind;
    // std::string and std::string_view from a str, a std::vector<T> from a T[..] (by value, const& or
    // &&: a C++ object the wrapper makes)
    var base = t;
    var mutable_ref = false;
    if (k == clang::CXType_LValueReference || k == clang::CXType_RValueReference) {
        base = clang::clang_getPointeeType(t);
        mutable_ref = k == clang::CXType_LValueReference && clang::clang_isConstQualifiedType(base) == 0;
    }
    if (!mutable_ref) {
        if (char_text(base, "basic_string")) {
            return { vty: S("str"), pass: S(name), cpp: fmt2("std::string((const char *){}.ptr, {}.len)", copy slot, copy slot) };
        }
        if (char_text(base, "basic_string_view")) {
            return { vty: S("str"), pass: S(name), cpp: fmt2("std::string_view((const char *){}.ptr, {}.len)", copy slot, copy slot) };
        }
        val st = std_template(base) ?? S("");
        if (st.as_str() == "vector") {
            val ct = clang::clang_getCanonicalType(base);
            val elem = this.vtype(clang::clang_Type_getTemplateArgumentAsType(ct, 0), tparams) ?? return null;
            var vec = type_spelling(ct);
            if (starts_with(vec.as_str(), "const ")) {
                vec = S(vec.as_str()[6..vec.len()]);
            }
            return { vty: fmt("{}[..]", move elem), pass: S(name), cpp: fmt4("{}({}.ptr, {}.ptr + {}.len)", move vec, copy slot, copy slot, copy slot) };
        }
        if (st.as_str() == "function") {
            // a Volt fn value: C++ gets a std::function calling its fn with its env (good while the
            // call is: C++ mustn't keep it)
            val sig = this.fn_sig(base) ?? return null;
            return { vty: copy sig.vty, pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt2("volt_cpp_fn<{}>({})", copy sig.args, copy slot) };
        }
    }
    // a class Volt holds by handle: its object, by reference (const& or &); by value or && C++ moves
    // from it (the Volt value still deletes what's left), or copies it when the handle only borrows it
    val hc = this.handle_of(base);
    if (hc) {
        val vt = this.vtype(base, tparams) ?? return null;
        if (k == clang::CXType_LValueReference) {
            return { vty: fmt("{}&", move vt), pass: fmt("{}.cpp", S(name)), cpp: fmt2("volt_cpp_obj<{}>({})", copy hc, copy slot) };
        }
        return { vty: move vt, pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt2("volt_cpp_take<{}>({})", copy hc, copy slot) };
    }
    if (k == clang::CXType_RValueReference) {
        // T&&: Volt hands the value over (a class by its place), C++ moves from it
        val pt = clang::clang_getPointeeType(t);
        for (p&) in tparams.items() {
            if (strip_const(type_spelling(pt).as_str()) == *p) {
                return { vty: S(*p), pass: fmt("&{}", S(name)), cpp: fmt("VOLT_MOVE({})", move slot) };
            }
        }
        val inner = this.vtype(pt, tparams) ?? return null;
        if (is_class(pt)) {
            return { vty: move inner, pass: fmt("&{}", S(name)), cpp: fmt("VOLT_MOVE({})", move slot) };
        }
        return { vty: move inner, pass: S(name), cpp: fmt("VOLT_MOVE({})", move slot) };
    }
    if (k == clang::CXType_LValueReference) {
        val pt = clang::clang_getPointeeType(t);
        var inner = this.vtype(pt, tparams) ?? return null;
        if (is_class(pt) || clang::clang_isConstQualifiedType(pt) == 0) {
            inner.push('&');
        }
        return { vty: move inner, pass: S(name), cpp: move slot };
    }
    val v = this.vtype(t, tparams) ?? return null;
    if (is_class(t)) {
        // a class by value: C++ moves from the Volt parameter (which still deletes what's left)
        return { vty: move v, pass: fmt("&{}", S(name)), cpp: fmt("VOLT_MOVE({})", move slot) };
    }
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_Enum) {
        return { vty: move v, pass: S(name), cpp: fmt2("({})({})", cpp_qual(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(t))), move slot) };
    }
    // a pointer as the parameter's own type (Volt's cstr is a const char *, for a char * one too);
    // not a template's T*, which only the template can spell
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_Pointer && !contains(canon(t).as_str(), "type-parameter")) {
        return { vty: move v, pass: S(name), cpp: fmt2("(VOLT_ID({}))({})", canon(t), move slot) };
    }
    return { vty: move v, pass: S(name), cpp: move slot };
}

// how a C++ result comes back: as @cpp's value, or as a std::string (std::vector) the wrapper
// copies out into malloc'd memory, which the Volt fn turns into its own std::string (std::vec) and
// frees, or as the bytes of a std::string_view
enum ret_way {
    PLAIN,
    STRING,
    VIEW,
    VECTOR,
    HANDLE, // a class Volt holds by handle: new T(result)
}

struct cpp_ret {
    vty: std::string;     // what the Volt fn returns
    way: ret_way = ret_way::PLAIN;
    elem: std::string = {}; // VECTOR: the element type
    object: bool = false;   // a C++ object by value (made in place: a try_ form can't hold one)
    cls: std::string = {};  // HANDLE: the C++ class
    up: std::string = {};   // HANDLE: the class the handle is of, when cls is a subclass of it
    pre: std::string = {};  // a statement before the call (derive's: making the Volt side)
    volt: std::string = {}; // HANDLE: the handle's volt field (derive's: the Volt side)
}

// the Volt return type of a C++ one (a reference to a class stays one; to a const number, a copy)
attach fn result(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> cpp_ret? {
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_RValueReference) {
        // T&&: what it refers to, by value (moved into a new object for a class held by handle,
        // which needs a move or copy constructor; copied otherwise)
        val to = clang::clang_getNonReferenceType(t);
        val hc = this.handle_of(to);
        if (hc) {
            if (!(this.traits.get(hc.as_str()) ?? return null)->movable) {
                return null;
            }
        }
        return this.result(to, tparams);
    }
    var base = t;
    if (t.kind == clang::CXType_LValueReference) {
        base = clang::clang_getPointeeType(t);
    }
    if (t.kind != clang::CXType_LValueReference || clang::clang_isConstQualifiedType(base) != 0) {
        if (char_text(base, "basic_string")) {
            return { vty: S("std::string"), way: ret_way::STRING };
        }
        if (char_text(base, "basic_string_view")) {
            return { vty: S("str"), way: ret_way::VIEW };
        }
        val st = std_template(base) ?? S("");
        if (st.as_str() == "vector") {
            val elem = this.vtype(clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(base), 0), tparams) ?? return null;
            return { vty: fmt("std::vec<{}>", copy elem), way: ret_way::VECTOR, elem: move elem };
        }
        if (st.as_str() == "function") {
            // a C++ callable Volt keeps (stdcxx::function, whose call(...) runs it)
            val sig = this.fn_sig(base) ?? return null;
            this.fn_sigs.put(this.c.intern(copy sig.cpp), clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(base), 0));
            return { vty: S("stdcxx::function"), way: ret_way::HANDLE, cls: fmt("volt_fn_holder<{}>", copy sig.cpp), up: S("volt_fn_box") };
        }
    }
    // a class Volt holds by handle: a new object made from the result; a const& one is copied, and a
    // reference into C++'s own object (or a class Volt can't delete) isn't one Volt can hold
    val hc = this.handle_of(base);
    if (hc) {
        val tr = this.traits.get(hc.as_str()) ?? return null;
        if (!tr->destructible || (t.kind == clang::CXType_LValueReference && (clang::clang_isConstQualifiedType(base) == 0 || !tr->copyable))) {
            return null;
        }
        val v = this.vtype(base, tparams) ?? return null;
        return { vty: move v, way: ret_way::HANDLE, cls: copy hc };
    }
    if (t.kind == clang::CXType_LValueReference) {
        var inner = this.vtype(base, tparams) ?? return null;
        if (is_class(base) || clang::clang_isConstQualifiedType(base) == 0) {
            inner.push('&');
        }
        return { vty: move inner };
    }
    val v = this.vtype(t, tparams) ?? return null;
    return { vty: move v, object: is_class(t) };
}

// a std::function's signature in Volt and C++: fn(i32, str) -> bool, "bool, int, std::string_view"
// (volt_cpp_fn's arguments) and "bool(int, std::string_view)"; none when a type in it isn't a number,
// bool, enum, pointer or text (or the result text)
struct fn_sig {
    vty: std::string;
    args: std::string;
    cpp: std::string;
}

attach fn fn_sig(this: cpp_gen&, t: clang::CXType) -> fn_sig? {
    val none: std::vec<str> = {};
    val f = clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(t), 0);
    if (f.kind != clang::CXType_FunctionProto) {
        return null;
    }
    val n = clang::clang_getNumArgTypes(f);
    if (n < 0) {
        return null;
    }
    val rt = clang::clang_getResultType(f);
    var vps: std::string = {};
    var cps: std::string = {};
    for (i) in 0..@cast<u32>(n) {
        val at = clang::clang_getArgType(f, i);
        var base = at;
        val ck = clang::clang_getCanonicalType(at).kind;
        if (ck == clang::CXType_LValueReference) {
            base = clang::clang_getPointeeType(clang::clang_getCanonicalType(at));
        }
        var v: std::string = {};
        if ((ck != clang::CXType_LValueReference || clang::clang_isConstQualifiedType(base) != 0) && (char_text(base, "basic_string") || char_text(base, "basic_string_view"))) {
            v = S("str");
        } else if (ck == clang::CXType_LValueReference || ck == clang::CXType_RValueReference || is_class(at)) {
            return null;
        } else {
            v = this.vtype(at, &none) ?? return null;
        }
        if (i > 0) {
            vps.append(", ");
            cps.append(", ");
        }
        vps.append(v.as_str());
        cps.append(canon(at).as_str());
    }
    var vr = S("void");
    if (clang::clang_getCanonicalType(rt).kind != clang::CXType_Void) {
        if (is_class(rt) || clang::clang_getCanonicalType(rt).kind == clang::CXType_LValueReference || clang::clang_getCanonicalType(rt).kind == clang::CXType_RValueReference) {
            return null;
        }
        vr = this.vtype(rt, &none) ?? return null;
    }
    var args = canon(rt);
    if (cps.len() > 0) {
        args.append(", ");
        args.append(cps.as_str());
    }
    return { vty: fmt2("fn({}) -> {}", move vps, move vr), args: move args, cpp: fmt2("{}({})", canon(rt), move cps) };
}

// stdcxx::function: a C++ callable a function returned, and call(...) for each signature one came
// back with (a call with another one's arguments stops the program)
attach fn fn_type(this: cpp_gen&) -> void {
    val none: std::vec<str> = {};
    this.line("// a std::function C++ gave Volt: call(...) runs it; deleting it deletes it");
    this.line("struct function {");
    this.line("    cpp: void* = null;");
    this.line("}");
    this.line("attach fn delete(this: function&) -> void {");
    this.line("    if (this.cpp != null) {");
    this.line("        @cpp<void>(\"delete (volt_fn_box *){0}\", this.cpp);");
    this.line("    }");
    this.line("}");
    for (e) in this.fn_sigs.iter() {
        val f = *e.value;
        val n = clang::clang_getNumArgTypes(f);
        var params: std::string = {};
        var passed = S(", this.cpp");
        var args: std::string = {};
        var ok = true;
        for (i) in 0..@cast<u32>(n) {
            val pn = fmt("a{}", unum(@cast<u64>(i)));
            val a = this.param(clang::clang_getArgType(f, i), pn.as_str(), @cast<usize>(i) + 1, &none);
            if (a) {
                params.append(fmt2(", {}: {}", copy pn, copy a.vty).as_str());
                passed.append(fmt(", {}", copy a.pass).as_str());
                if (i > 0) {
                    args.append(", ");
                }
                args.append(a.cpp.as_str());
            } else {
                ok = false;
            }
        }
        var r = this.result(clang::clang_getResultType(f), &none) ?? continue;
        if (!ok) {
            continue;
        }
        if (!this.first_time(fmt2("attach fn call(this: function&{}) -> {}", copy params, copy r.vty).as_str(), "")) {
            this.line(fmt("// (no call for a std::function<{}>: another signature's has its Volt types)", S(*e.key)).as_str());
            continue;
        }
        val expr = fmt2("volt_cpp_holder<{}>({{0}})({})", S(*e.key), move args);
        this.fn_text("", fmt2("attach fn call(this: function&{}) -> {}", move params, copy r.vty).as_str(), &r, expr.as_str(), passed.as_str(), "");
    }
}

// can the function throw (it isn't noexcept or throw())?
fn may_throw(c: clang::CXCursor) -> bool {
    val k = clang::clang_getCursorExceptionSpecificationType(c);
    return k != clang::CXCursor_ExceptionSpecificationKind_BasicNoexcept && k != clang::CXCursor_ExceptionSpecificationKind_DynamicNone && k != clang::CXCursor_ExceptionSpecificationKind_NoThrow;
}

// the C++ operator a function or method is (operator+ is op_add), by how many operands it has; none
// for what has no name here (assignment, conversions, new and delete, ->, comma, postfix ++ and --)
fn op_name(name: str, operands: usize) -> str? {
    if (!starts_with(name, "operator")) {
        return null;
    }
    val sym = trim(name[8..name.len]);
    if (sym == "()") {
        return "op_call";
    }
    if (operands == 1) {
        val unary: str[7] = { "-", "+", "!", "~", "*", "++", "--" };
        val names: str[7] = { "op_neg", "op_pos", "op_not", "op_bitnot", "op_deref", "op_inc", "op_dec" };
        for (i) in 0..7 {
            if (sym == unary[i]) {
                return names[i];
            }
        }
        return null;
    }
    if (operands != 2) {
        return null;
    }
    val binary: str[30] = { "+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "&&", "||", "[]", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "=" };
    val names: str[30] = { "op_add", "op_sub", "op_mul", "op_div", "op_rem", "op_eq", "op_ne", "op_lt", "op_le", "op_gt", "op_ge", "op_bitand", "op_bitor", "op_xor", "op_shl", "op_shr", "op_and", "op_or", "op_index", "op_add_assign", "op_sub_assign", "op_mul_assign", "op_div_assign", "op_rem_assign", "op_bitand_assign", "op_bitor_assign", "op_xor_assign", "op_shl_assign", "op_shr_assign", "assign" };
    for (i) in 0..30 {
        if (sym == binary[i]) {
            return names[i];
        }
    }
    return null;
}

// a function's parameters: clang_Cursor_getArgument's, or for a template (which it doesn't answer
// for) the ParmDecls under it (a function type in its result has some of its own: int(int) in
// std::function<int(int)>, so they're only the fallback)
fn params_of(c: clang::CXCursor) -> std::vec<clang::CXCursor> {
    var out: std::vec<clang::CXCursor> = {};
    val n = clang::clang_Cursor_getNumArguments(c);
    if (n >= 0) {
        for (i) in 0..@cast<u32>(n) {
            put(&out, clang::clang_Cursor_getArgument(c, i));
        }
        return out;
    }
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_ParmDecl) {
            put(&out, *ch);
        }
    }
    val want = clang::clang_getNumArgTypes(clang::clang_getCursorType(c));
    if (want >= 0 && out.len > @cast<usize>(want)) {
        var last: std::vec<clang::CXCursor> = {};
        for (i) in out.len - @cast<usize>(want)..out.len {
            put(&last, *out.at(i));
        }
        return last;
    }
    return out;
}

// how many parameters a function cursor has
fn param_count(c: clang::CXCursor) -> usize {
    return params_of(c).len;
}

// ---------- functions ----------

// one Volt fn per way to call a C++ function or method: `head` is the Volt signature up to its
// params (`attach fn area(this: Shape&` or `fn add(`), `call` the C++ expression up to its args
// (`{0}.area(` or `geo::add(`); `first` is the @cpp index of the first C++ argument; self_arg is
// what the Volt fn passes first (this), if anything. A default argument adds an overload without
// it, and one that can throw a try_ form too
attach fn callable(this: cpp_gen&, generics: str, head: str, has_params: bool, fn_cursor: clang::CXCursor, ret: cpp_ret?, call: str, self_arg: str?, extra: str, tparams: std::vec<str>&, what: str) -> void {
    this.note = cpp_decl_text(fn_cursor);
    this.callable_of(generics, head, has_params, fn_cursor, ret, call, self_arg, extra, tparams, what);
    this.note = {};
}

// the C++ declaration the next fn wraps, as the comment above it (once)
attach fn put_note(this: cpp_gen&) -> void {
    if (this.note.len() > 0) {
        this.line(fmt("// C++: {}", copy this.note).as_str());
        this.note = {};
    }
}

// a C++ function's declaration on one line: `double geo::scale(double x, int k) const`
fn cpp_decl_text(c: clang::CXCursor) -> std::string {
    var out: std::string = {};
    val k = clang::clang_getCursorKind(c);
    if (k == clang::CXCursor_FunctionTemplate) {
        var tps: std::vec<std::string> = {};
        for (ch&) in children(c).items() {
            val ck = clang::clang_getCursorKind(*ch);
            if (ck == clang::CXCursor_TemplateTypeParameter) {
                put(&tps, fmt("class {}", cursor_name(*ch)));
            } else if (ck == clang::CXCursor_NonTypeTemplateParameter) {
                put(&tps, fmt2("{} {}", type_spelling(clang::clang_getCursorType(*ch)), cursor_name(*ch)));
            }
        }
        out.append("template <");
        for (i) in 0..tps.len {
            if (i > 0) {
                out.append(", ");
            }
            out.append(tps.at(i).as_str());
        }
        out.append("> ");
    }
    if (clang::clang_CXXMethod_isStatic(c) != 0) {
        out.append("static ");
    }
    if (clang::clang_CXXMethod_isVirtual(c) != 0) {
        out.append("virtual ");
    }
    if (k != clang::CXCursor_Constructor && k != clang::CXCursor_Destructor) {
        out.append(type_spelling(clang::clang_getCursorResultType(c)).as_str());
        out.push(' ');
    }
    out.append(cpp_qual(c).as_str());
    out.push('(');
    val ps = params_of(c);
    for (i) in 0..ps.len {
        if (i > 0) {
            out.append(", ");
        }
        out.append(type_spelling(clang::clang_getCursorType(*ps.at(i))).as_str());
        val n = cursor_name(*ps.at(i));
        if (n.len() > 0) {
            out.push(' ');
            out.append(n.as_str());
        }
    }
    if (clang::clang_Cursor_isVariadic(c) != 0) {
        if (ps.len > 0) {
            out.append(", ");
        }
        out.append("...");
    }
    out.push(')');
    if (clang::clang_CXXMethod_isConst(c) != 0) {
        out.append(" const");
    }
    return out;
}

attach fn callable_of(this: cpp_gen&, generics: str, head: str, has_params: bool, fn_cursor: clang::CXCursor, ret: cpp_ret?, call: str, self_arg: str?, extra: str, tparams: std::vec<str>&, what: str) -> void {
    var r: cpp_ret = { vty: S("void") };
    if (ret) {
        r = copy ret;
    } else {
        // its result hangs on the call (auto, a template's): clang types each call
        this.per_use(head, call, self_arg != null);
        return;
    }
    val parms = params_of(fn_cursor);
    var args: std::vec<cpp_arg> = {};
    var names: std::vec<std::string> = {};
    var optional: usize = 0;
    // the arguments before the parameters' (self_arg: one or more)
    val first = args_in(self_arg ?? "");
    for (i) in 0..parms.len {
        val p = *parms.at(i);
        var pn = cursor_name(p);
        if (pn.len() == 0) {
            pn = S("a");
            pn.append_uint(@cast<u64>(i));
        }
        val name = vname(pn.as_str());
        var a: cpp_arg = { vty: {}, pass: {}, cpp: {} };
        val ao = this.param(clang::clang_getCursorType(p), name.as_str(), first + @cast<usize>(i), tparams);
        if (ao) {
            a = copy ao;
        } else {
            // a parameter pack, or a type only a call settles: clang types each call
            this.per_use(head, call, self_arg != null);
            return;
        }
        // a default argument shows up as an expression under the parameter
        var has_default = false;
        for (ch&) in children(p).items() {
            if (clang::clang_isExpression(clang::clang_getCursorKind(*ch)) != 0) {
                has_default = true;
            }
        }
        if (has_default) {
            optional += 1;
        } else {
            optional = 0;
        }
        put(&args, move a);
        put(&names, move name);
    }
    // a try_ form: when it can throw, and its result is something a zeroed local can hold
    val can_try = may_throw(fn_cursor) && r.way != ret_way::VECTOR && r.way != ret_way::HANDLE && !r.object && !ends_with(r.vty.as_str(), "&") && !ends_with(r.vty.as_str(), "?");
    // every count of trailing default arguments, most first
    var drop: usize = 0;
    while (drop <= optional) {
        val count = args.len - drop;
        var params: std::string = {};
        var call_args: std::string = {};
        var passed: std::string = {};
        var n_passed: usize = 0;
        if (self_arg) {
            passed.append(self_arg);
            n_passed = first;
        }
        for (i) in 0..count {
            if (i > 0 || has_params) {
                params.append(", ");
            }
            params.append(fmt2("{}: {}", copy *names.at(i), copy args.at(i).vty).as_str());
            if (i > 0) {
                call_args.append(", ");
            }
            call_args.append(args.at(i).cpp.as_str());
            if (passed.len() > 0) {
                passed.append(", ");
            }
            passed.append(args.at(i).pass.as_str());
            n_passed += 1;
        }
        var types: std::string = {};
        for (i) in 0..count {
            types.push(',');
            types.append(args.at(i).vty.as_str());
        }
        if (!this.first_time(head, types.as_str())) {
            drop += 1;
            continue;
        }
        // the C++ call, and what @cpp passes it
        var cpp = S(call);
        cpp.append(call_args.as_str());
        cpp.push(')');
        var tail: std::string = {};
        if (passed.len() > 0) {
            tail = fmt(", {}", copy passed);
        }
        this.fn_text(generics, fmt3("{}{}) -> {}", S(head), copy params, copy r.vty).as_str(), &r, cpp.as_str(), tail.as_str(), extra);
        if (can_try) {
            this.try_text(generics, head, params.as_str(), &r, cpp.as_str(), tail.as_str(), n_passed, extra);
        }
        drop += 1;
    }
}

// false when this signature (its head, and its parameters' types as ",T,U") was written already in
// this namespace; else it's noted as written
attach fn first_time(this: cpp_gen&, head: str, types: str) -> bool {
    var key = copy this.scope;
    key.push('|');
    key.append(head);
    key.append(types);
    if (this.written.get(key.as_str()) != null) {
        return false;
    }
    this.written.put(this.c.intern(move key), true);
    return true;
}

// a Volt fn whose body makes the C++ call (sig: its signature up to the result type)
attach fn fn_text(this: cpp_gen&, generics: str, sig: str, r: cpp_ret&, cpp: str, tail: str, extra: str) -> void {
    this.put_note();
    if (generics.len > 0) {
        this.line(generics);
    }
    this.line(fmt("{} {{", S(sig)).as_str());
    this.depth += 1;
    if (r.pre.len() > 0) {
        this.line(r.pre.as_str());
    }
    match (r.way) {
        .PLAIN => {
            var body: std::string = {};
            if (r.vty.as_str() != "void") {
                body.append("return ");
            }
            body.append(fmt4("@cpp<{}{}>(\"{}\"{});", copy r.vty, S(extra), S(cpp), S(tail)).as_str());
            this.line(body.as_str());
        },
        .VIEW => { this.line(fmt3("return @cpp<str{}>(\"volt_cpp_view({})\"{});", S(extra), S(cpp), S(tail)).as_str()); },
        .HANDLE => {
            var made = fmt2("new {}({})", copy r.cls, S(cpp));
            if (r.up.len() > 0) {
                made = fmt2("static_cast<{} *>({})", copy r.up, move made);
            }
            var vf = S("");
            if (r.volt.len() > 0) {
                vf = fmt(", volt: {}", copy r.volt);
            }
            this.line(fmt4("return {{ cpp: @cpp<void*{}>(\"{}\"{}){} }};", S(extra), move made, S(tail), move vf).as_str());
        },
        .STRING => {
            this.line(fmt3("val try_got = @cpp<str{}>(\"volt_cpp_dup({})\"{});", S(extra), S(cpp), S(tail)).as_str());
            this.text_out("try_got");
        },
        .VECTOR => {
            this.line(fmt4("val try_got = @cpp<{}[..]{}>(\"volt_cpp_dup_vec({})\"{});", copy r.elem, S(extra), S(cpp), S(tail)).as_str());
            this.line(fmt("var try_vec: std::vec<{}> = {{}};", copy r.elem).as_str());
            this.line("try_vec.extend(try_got) catch |try_e| {");
            this.line("    @panic(\"out of memory\");");
            this.line("};");
            this.line("@cpp<void>(\"std::free((void *){0}.ptr)\", try_got);");
            this.line("return try_vec;");
        },
    }
    this.depth -= 1;
    this.line("}");
}

// the lines turning text the wrapper copied out (str r, malloc'd) into a std::string, and returning
// it (the generated locals start with try_, so a C++ parameter of an ordinary name can't clash)
attach fn text_out(this: cpp_gen&, r: str) -> void {
    this.line(fmt("var try_text = std::string::from({});", S(r)).as_str());
    this.line(fmt("@cpp<void>(\"std::free((void *){0}.ptr)\", {});", S(r)).as_str());
    this.line("return try_text;");
}

// the try_ form of a call: a cpp_error naming the exception when it throws (last_exception() says
// what it said)
attach fn try_text(this: cpp_gen&, generics: str, head: str, params: str, r: cpp_ret&, cpp: str, tail: str, n_passed: usize, extra: str) -> void {
    // `attach fn area(this: Shape&` gives `attach fn try_area(this: Shape&`
    var h = S(head);
    var at: usize = 0;
    if (starts_with(head, "attach fn ")) {
        at = 10;
    } else if (starts_with(head, "fn ")) {
        at = 3;
    }
    h = fmt3("{}try_{}", S(head[0..at]), S(head[at..head.len]), S(""));
    if (generics.len > 0) {
        this.line(generics);
    }
    val rv = r.vty.as_str();
    var inner = S("void");
    if (r.way == ret_way::STRING || r.way == ret_way::VIEW) {
        inner = S("str");
    } else if (rv != "void") {
        inner = S(rv);
    }
    this.tries = true;
    this.line(fmt3("{}{}) -> cpp_error!{} {{", move h, S(params), copy r.vty).as_str());
    this.depth += 1;
    var lambda: std::string = {};
    var all_tail = S(tail);
    if (inner.as_str() == "void") {
        lambda = S(cpp);
    } else {
        this.line(fmt("var try_out: {};", copy inner).as_str());
        var conv = S(cpp);
        if (r.way == ret_way::STRING) {
            conv = fmt("volt_cpp_dup({})", S(cpp));
        } else if (r.way == ret_way::VIEW) {
            conv = fmt("volt_cpp_view({})", S(cpp));
        }
        // converted to the out variable's own type (an enum to its tag, say)
        val slot = fmt("{{{}}}", unum(@cast<u64>(n_passed)));
        lambda = fmt3("{} = static_cast<VOLT_NOREF({})>({})", copy slot, copy slot, move conv);
        if (all_tail.len() == 0) {
            all_tail = S(", &try_out");
        } else {
            all_tail.append(", &try_out");
        }
    }
    this.line(fmt4("val try_k = @cpp<i32{}>(\"VOLT_CPP_TRY({}, {})\"{});", S(extra), copy this.kinds, move lambda, move all_tail).as_str());
    this.line("if (try_k != 0) {");
    this.line("    return volt_cpp_error_of(try_k);");
    this.line("}");
    if (r.way == ret_way::STRING) {
        this.text_out("try_out");
    } else if (inner.as_str() != "void") {
        this.line("return try_out;");
    } else {
        this.line("return;");
    }
    this.depth -= 1;
    this.line("}");
}

// the type parameters of a template cursor (none if it has a non-type or template parameter)
// a template's type parameters, the ones Volt passes: up to the first with a default, which C++
// fills in (typename = std::enable_if_t<...>); none when one Volt can't pass comes first (a value
// or template parameter, an unnamed one without a default)
fn template_params(c: clang::CXCursor) -> std::vec<std::string>? {
    var out: std::vec<std::string> = {};
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_TemplateTypeParameter) {
            // a default shows up as what's under the parameter
            if (children(*ch).len > 0) {
                break;
            }
            val name = cursor_name(*ch);
            if (name.len() == 0) {
                return null;
            }
            put(&out, move name);
        } else if (k == clang::CXCursor_NonTypeTemplateParameter || k == clang::CXCursor_TemplateTemplateParameter) {
            // a default is an expression (or a template's name) under it; its own type's parts
            // (int (*F)(int)'s parameter) and parameters aren't
            for (d&) in children(*ch).items() {
                val dk = clang::clang_getCursorKind(*d);
                if (clang::clang_isExpression(dk) != 0 || dk == clang::CXCursor_TemplateRef) {
                    return out;
                }
            }
            return null;
        }
    }
    return out;
}

fn generics_text(ps: std::vec<std::string>&) -> std::string {
    if (ps.len == 0) {
        return {};
    }
    var s = S("<");
    for (i) in 0..ps.len {
        if (i > 0) {
            s.append(", ");
        }
        s.append(ps.at(i).as_str());
        s.append(": type");
    }
    s.push('>');
    return s;
}

// ", T, U": the extra @cpp type arguments a template's {t0}, {t1} stand for
fn extra_types(ps: std::vec<std::string>&) -> std::string {
    var s: std::string = {};
    for (p&) in ps.items() {
        s.append(", ");
        s.append(p.as_str());
    }
    return s;
}

// "geo::biggest<{t0}, {t1}>"
fn cpp_template_ref(q: str, n: usize) -> std::string {
    var s = S(q);
    s.push('<');
    for (i) in 0..n {
        if (i > 0) {
            s.append(", ");
        }
        s.append(fmt("{t{}}", unum(@cast<u64>(i))).as_str());
    }
    s.push('>');
    return s;
}

fn str_views(v: std::vec<std::string>&) -> std::vec<str> {
    var out: std::vec<str> = {};
    for (s&) in v.items() {
        put(&out, s.as_str());
    }
    return out;
}

attach fn free_fn(this: cpp_gen&, c: clang::CXCursor, tps: std::vec<std::string>&) -> void {
    var name = cursor_name(c);
    if (clang::clang_CXXMethod_isDeleted(c) != 0) {
        return;
    }
    if (starts_with(name.as_str(), "operator")) {
        name = S(op_name(name.as_str(), param_count(c)) ?? return);
    }
    val tp = str_views(tps);
    var call = cpp_qual(c);
    if (tps.len > 0) {
        call = cpp_template_ref(call.as_str(), tps.len);
    }
    call.push('(');
    val head = fmt("fn {}(", vname(name.as_str()));
    val ret = this.result(clang::clang_getCursorResultType(c), &tp);
    this.callable(generics_text(tps).as_str(), head.as_str(), false, c, ret, call.as_str(), null, extra_types(tps).as_str(), &tp, name.as_str());
}

// ---------- classes ----------

// does the class need Volt's delete hook (a destructor that does something, its own or a member's)?
fn nontrivial(c: clang::CXCursor, depth: u32) -> bool {
    if (depth > 16) {
        return true;
    }
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_Destructor && (clang::clang_CXXMethod_isDefaulted(*ch) == 0 || clang::clang_CXXMethod_isVirtual(*ch) != 0)) {
            return true;
        }
        if (k == clang::CXCursor_CXXMethod && clang::clang_CXXMethod_isVirtual(*ch) != 0) {
            return true;
        }
        if (k == clang::CXCursor_Constructor && clang::clang_CXXConstructor_isCopyConstructor(*ch) != 0 && clang::clang_CXXMethod_isDefaulted(*ch) == 0 && clang::clang_CXXMethod_isDeleted(*ch) == 0) {
            return true;
        }
        if (k == clang::CXCursor_FieldDecl || k == clang::CXCursor_CXXBaseSpecifier) {
            var t = clang::clang_getCanonicalType(clang::clang_getCursorType(*ch));
            while (t.kind == clang::CXType_ConstantArray) {
                t = clang::clang_getCanonicalType(clang::clang_getArrayElementType(t));
            }
            if (t.kind == clang::CXType_Record && nontrivial(clang::clang_getTypeDeclaration(t), depth + 1)) {
                return true;
            }
        }
    }
    return false;
}

// can it be copied: a copy constructor that isn't deleted, or an implicit one (no move declared,
// and every member and base can be copied)
fn copyable(c: clang::CXCursor, depth: u32) -> bool {
    if (depth > 16) {
        return false;
    }
    var implicit = true;
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_Constructor && clang::clang_CXXConstructor_isCopyConstructor(*ch) != 0) {
            return clang::clang_CXXMethod_isDeleted(*ch) == 0 && clang::clang_getCXXAccessSpecifier(*ch) == clang::CX_CXXPublic;
        }
        if ((k == clang::CXCursor_Constructor && clang::clang_CXXConstructor_isMoveConstructor(*ch) != 0) || (k == clang::CXCursor_CXXMethod && clang::clang_CXXMethod_isMoveAssignmentOperator(*ch) != 0)) {
            implicit = false;
        }
        if (k == clang::CXCursor_FieldDecl || k == clang::CXCursor_CXXBaseSpecifier) {
            var t = clang::clang_getCanonicalType(clang::clang_getCursorType(*ch));
            while (t.kind == clang::CXType_ConstantArray) {
                t = clang::clang_getCanonicalType(clang::clang_getArrayElementType(t));
            }
            if (t.kind == clang::CXType_Record && !copyable(clang::clang_getTypeDeclaration(t), depth + 1)) {
                implicit = false;
            }
        }
    }
    return implicit;
}

fn is_public(c: clang::CXCursor) -> bool {
    return clang::clang_getCXXAccessSpecifier(c) == clang::CX_CXXPublic;
}

// padding for bytes [from, to) as Volt fields (the widest aligned unsigned ints that fit)
attach fn pads(this: cpp_gen&, from: u64, to: u64, big: bool, n: u32&, align: u64&) -> void {
    var at = from;
    while (at < to) {
        var size: u64 = 1;
        if (big && at % 16 == 0 && at + 16 <= to) {
            size = 16;
        } else if (at % 8 == 0 && at + 8 <= to) {
            size = 8;
        } else if (at % 4 == 0 && at + 4 <= to) {
            size = 4;
        } else if (at % 2 == 0 && at + 2 <= to) {
            size = 2;
        }
        var count: u64 = 1;
        if (size >= 8) {
            count = (to - at) / size;
        }
        if (size > *align) {
            *align = size;
        }
        if (count > 1) {
            this.line(fmt3("_volt_pad{}: u{}[{}] = {{}};", unum(@cast<u64>(*n)), unum(size * 8), unum(count)).as_str());
        } else {
            this.line(fmt2("_volt_pad{}: u{} = 0;", unum(@cast<u64>(*n)), unum(size * 8)).as_str());
        }
        *n += 1;
        at += size * count;
    }
}

// a class's struct: its public fields at their offsets, padding around them (so Volt's layout is
// C++'s); false when that can't be done (its alignment comes from something padding can't copy)
attach fn class_struct(this: cpp_gen&, c: clang::CXCursor, vname_: str, q: str) -> bool {
    val t = clang::clang_getCursorType(c);
    val size = clang::clang_Type_getSizeOf(t);
    val align = clang::clang_Type_getAlignOf(t);
    if (size <= 0 || align <= 0) {
        return false;
    }
    val start = this.out.len();
    this.line(fmt("@attributes([@cpp_type(\"{}\")])", S(q)).as_str());
    this.line(fmt("struct {} {{", S(vname_)).as_str());
    this.depth += 1;
    var at: u64 = 0;
    var got: u64 = 1;
    var n: u32 = 0;
    val none: std::vec<str> = {};
    for (f&) in children(c).items() {
        if (clang::clang_getCursorKind(*f) != clang::CXCursor_FieldDecl || !is_public(*f) || clang::clang_Cursor_isBitField(*f) != 0) {
            continue;
        }
        val ft = clang::clang_getCursorType(*f);
        if (ft.kind == clang::CXType_LValueReference || ft.kind == clang::CXType_RValueReference) {
            continue;
        }
        val vt = this.vtype(ft, &none) ?? continue;
        val bits = clang::clang_Cursor_getOffsetOfField(*f);
        val fsize = clang::clang_Type_getSizeOf(ft);
        val falign = clang::clang_Type_getAlignOf(ft);
        if (bits < 0 || bits % 8 != 0 || fsize <= 0 || @cast<u64>(bits / 8) < at) {
            continue;
        }
        this.pads(at, @cast<u64>(bits / 8), align >= 16, &n, &got);
        this.line(fmt2("{}: {};", vname(cursor_name(*f).as_str()), move vt).as_str());
        at = @cast<u64>(bits / 8) + @cast<u64>(fsize);
        if (@cast<u64>(falign) > got) {
            got = @cast<u64>(falign);
        }
    }
    this.pads(at, @cast<u64>(size), align >= 16, &n, &got);
    this.depth -= 1;
    this.line("}");
    if (got != @cast<u64>(align)) {
        // take the struct back out
        this.out.bytes.len = start;
        this.line(fmt2("// left out: class {} (its alignment, {}, comes from members Volt can't show)", S(q), num(@cast<i128>(align))).as_str());
        return false;
    }
    return true;
}

// a class (or class template): its struct, constructors, hooks and methods
attach fn class(this: cpp_gen&, c: clang::CXCursor, tps: std::vec<std::string>?) -> void {
    val name = cursor_name(c);
    if (name.len() == 0) {
        return;
    }
    val q = cpp_qual(c);
    var path = this.classes.get(q.as_str());
    if (tps) {
        path = this.templates.get(q.as_str());
    }
    var vn = vname(name.as_str());
    if (path) {
        vn = last_part(*path, name.as_str());
    }
    var gen: std::string = {};
    var self_ty = copy vn;
    var cpp_self = copy q;
    var tp: std::vec<str> = {};
    var extra: std::string = {};
    if (tps) {
        // a class template: Volt lays out its public fields itself, so it can only have those
        for (ch&) in children(c).items() {
            val k = clang::clang_getCursorKind(*ch);
            if ((k == clang::CXCursor_FieldDecl && !is_public(*ch)) || k == clang::CXCursor_CXXBaseSpecifier || (k == clang::CXCursor_CXXMethod && clang::clang_CXXMethod_isVirtual(*ch) != 0)) {
                this.line(fmt("// left out: class template {} (it has private fields, bases or virtual methods)", copy q).as_str());
                return;
            }
        }
        tp = str_views(&tps);
        gen = generics_text(&tps);
        self_ty.push('<');
        for (i) in 0..tps.len {
            if (i > 0) {
                self_ty.append(", ");
            }
            self_ty.append(tps.at(i).as_str());
        }
        self_ty.push('>');
        cpp_self = cpp_template_ref(q.as_str(), tps.len);
        extra = extra_types(&tps);
        this.line(gen.as_str());
        this.line(fmt("@attributes([@cpp_type(\"{}\")])", copy q).as_str());
        this.line(fmt("struct {} {{", copy vn).as_str());
        this.depth += 1;
        for (ch&) in children(c).items() {
            if (clang::clang_getCursorKind(*ch) == clang::CXCursor_FieldDecl) {
                // a class held by handle isn't laid out as C++ lays it out
                var vt: std::string? = null;
                if (this.handle_of(clang::clang_getCursorType(*ch)) == null) {
                    vt = this.vtype(clang::clang_getCursorType(*ch), &tp);
                }
                if (vt) {
                    this.line(fmt2("{}: {};", vname(cursor_name(*ch).as_str()), copy vt).as_str());
                } else {
                    this.depth -= 1;
                    this.line("}");
                    this.line(fmt("// (class template {}: a field's type isn't one Volt can use)", copy q).as_str());
                    return;
                }
            }
        }
        this.depth -= 1;
        this.line("}");
    } else if (this.handle_of(clang::clang_getCursorType(c)) != null) {
        this.handle_class(c, vn.as_str(), q.as_str());
        return;
    } else if (!this.class_struct(c, vn.as_str(), q.as_str())) {
        return;
    }
    val abstract_ = clang::clang_CXXRecord_isAbstract(c) != 0;
    var any_ctor = false;
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_Constructor) {
            any_ctor = true;
            if (!is_public(*ch) || abstract_ || clang::clang_CXXMethod_isDeleted(*ch) != 0 || clang::clang_CXXConstructor_isCopyConstructor(*ch) != 0 || clang::clang_CXXConstructor_isMoveConstructor(*ch) != 0) {
                continue;
            }
            val head = fmt("attach fn new(static this: {}", copy self_ty);
            var call = copy cpp_self;
            call.push('(');
            val made: cpp_ret = { vty: copy self_ty, object: true };
            this.callable(gen.as_str(), head.as_str(), true, *ch, made, call.as_str(), null, extra.as_str(), &tp, fmt("{}'s constructor", copy q).as_str());
        }
    }
    // T::new() when it declares no constructor and can be made from nothing, as clang says (a class
    // template's instances aren't asked)
    var defaults = !abstract_;
    val tr = this.traits.get(q.as_str());
    if (tr != null) {
        defaults = tr->defaults;
    }
    if (!any_ctor && defaults) {
        if (gen.len() > 0) {
            this.line(gen.as_str());
        }
        this.line(fmt2("attach fn new(static this: {}) -> {} {{", copy self_ty, copy self_ty).as_str());
        this.line(fmt3("    return @cpp<{}{}>(\"{}()\");", copy self_ty, copy extra, copy cpp_self).as_str());
        this.line("}");
    }
    if (nontrivial(c, 0)) {
        if (gen.len() > 0) {
            this.line(gen.as_str());
        }
        this.line(fmt("attach fn delete(this: {}&) -> void {{", copy self_ty).as_str());
        this.line(fmt2("    @cpp<void{}>(\"{0}.~{}()\", this);", copy extra, copy name).as_str());
        this.line("}");
        if (copyable(c, 0)) {
            if (gen.len() > 0) {
                this.line(gen.as_str());
            }
            this.line(fmt2("attach fn copy(this: {}&) -> {} {{", copy self_ty, copy self_ty).as_str());
            this.line(fmt3("    return @cpp<{}{}>(\"{}({0})\", this);", copy self_ty, copy extra, copy cpp_self).as_str());
            this.line("}");
        }
    }
    this.members(c, self_ty.as_str(), cpp_self.as_str(), "{0}", "this", gen.as_str(), extra.as_str(), &tp, q.as_str());
}

// a class that isn't trivially copyable: a handle to an object C++ allocates, so a Volt move moves
// only the pointer and the object never changes place (it may point into itself, as libstdc++'s
// std::string does)
attach fn handle_class(this: cpp_gen&, c: clang::CXCursor, vn: str, q: str) -> void {
    val tr = *(this.traits.get(q) ?? return);
    // the virtual methods a Volt type deriving from it overrides (attach vn -> T stands for their
    // trait)
    var maps: std::vec<virt_map>? = null;
    var vs: std::vec<virt> = {};
    if (tr.polymorphic && !tr.final_ && tr.vdtor) {
        maps = this.virt_maps(c, q, &vs);
    }
    this.line(fmt("// C++'s {}: it isn't trivially copyable, so Volt holds it by handle (C++ allocates it)", S(q)).as_str());
    if (maps) {
        this.line(fmt("@attributes([@attach_as(\"{}_virtuals\")])", S(vn)).as_str());
    }
    this.line(fmt("struct {} {{", S(vn)).as_str());
    // {} makes the object as C++'s T{} would, or is a compile error: a handle is never empty
    val abstract0 = clang::clang_CXXRecord_isAbstract(c) != 0;
    if (tr.defaults && tr.destructible && !abstract0) {
        this.line(fmt("    cpp: void* = @cpp<void*>(\"new {}()\"); // the C++ object ({} makes one)", S(q)).as_str());
    } else {
        this.line(fmt2("    cpp: void* = @compile_error(\"C++'s {} can't be made from nothing: make one with {}::new(...)\"); // the C++ object", S(q), S(vn)).as_str());
    }
    this.line("    borrowed: bool = false; // the object is something else's (as_Base made it): not deleted");
    if (maps) {
        this.line("    volt: void* = null; // the Volt side, when derive made the object (or it's a method's self)");
    }
    this.line("}");
    // the object, in a C++ expression (an empty handle stops the program)
    val obj = fmt("volt_cpp_obj<{}>({{0}})", S(q));
    val none: std::vec<str> = {};
    val abstract_ = clang::clang_CXXRecord_isAbstract(c) != 0;
    // Volt makes (and copies) only objects it can delete
    var any_ctor = false;
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) != clang::CXCursor_Constructor) {
            continue;
        }
        any_ctor = true;
        if (!tr.destructible || !is_public(*ch) || abstract_ || clang::clang_CXXMethod_isDeleted(*ch) != 0 || clang::clang_CXXConstructor_isCopyConstructor(*ch) != 0 || clang::clang_CXXConstructor_isMoveConstructor(*ch) != 0) {
            continue;
        }
        val made: cpp_ret = { vty: S(vn), way: ret_way::HANDLE, cls: S(q) };
        this.callable("", fmt("attach fn new(static this: {}", S(vn)).as_str(), true, *ch, made, fmt("{}(", S(q)).as_str(), null, "", &none, fmt("{}'s constructor", S(q)).as_str());
    }
    if (!tr.destructible) {
        this.line(fmt("// (its destructor isn't public: Volt has no {}::new)", S(q)).as_str());
        this.class_methods(c, vn, q, obj.as_str());
        return;
    }
    if (!any_ctor && tr.defaults) {
        this.line(fmt2("attach fn new(static this: {}) -> {} {{", S(vn), S(vn)).as_str());
        this.line(fmt("    return {{ cpp: @cpp<void*>(\"new {}()\") }};", S(q)).as_str());
        this.line("}");
    }
    this.line(fmt("attach fn delete(this: {}&) -> void {{", S(vn)).as_str());
    this.line("    if (this.cpp != null && !this.borrowed) {");
    this.line(fmt("        @cpp<void>(\"delete ({} *){{0}}\", this.cpp);", S(q)).as_str());
    this.line("    }");
    this.line("}");
    if (tr.copyable) {
        this.line(fmt2("attach fn copy(this: {}&) -> {} {{", S(vn), S(vn)).as_str());
        this.line("    if (this.cpp == null) {");
        this.line("        return { cpp: null };");
        this.line("    }");
        this.line(fmt2("    return {{ cpp: @cpp<void*>(\"new {}(*({} *){{0}})\", this.cpp) }};", S(q), S(q)).as_str());
        this.line("}");
    }
    // the methods before the fields' getters and set_ methods, so a method of the same signature
    // (a set_x of its own) is the one Volt calls
    this.class_methods(c, vn, q, obj.as_str());
    for (f&) in children(c).items() {
        if (clang::clang_getCursorKind(*f) == clang::CXCursor_FieldDecl && is_public(*f)) {
            this.field_accessors(*f, vn, fmt2("{}.{}", copy obj, cursor_name(*f)).as_str());
        }
    }
    this.casts(c, vn, q);
    // the object's type, as C++ names it (its dynamic type, for a class with virtual methods)
    if (this.first_time(fmt("attach fn cpp_type_name(this: {}&", S(vn)).as_str(), "")) {
        val r: cpp_ret = { vty: S("std::string"), way: ret_way::STRING };
        this.fn_text("", fmt("attach fn cpp_type_name(this: {}&) -> std::string", S(vn)).as_str(), &r, fmt("volt_cpp_type_name({})", copy obj).as_str(), ", this.cpp", "");
    }
    if (maps) {
        this.director(c, vn, q, &maps, &vs);
    }
}

// class c's bases (direct and through others), by every path: each one's cursor, whether it's
// reached by public inheritance all the way, and whether it's a virtual base (one object however
// many paths reach it)
struct base_path {
    c: clang::CXCursor;
    public_: bool;
    virtual_: bool;
}

fn all_bases(c: clang::CXCursor, public_: bool, out: std::vec<base_path>&, depth: u32) -> void {
    if (depth > 16) {
        return;
    }
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) != clang::CXCursor_CXXBaseSpecifier) {
            continue;
        }
        val b = clang::clang_getCursorDefinition(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(clang::clang_getCursorType(*ch))));
        if (clang::clang_Cursor_isNull(b) != 0) {
            continue;
        }
        val pub = public_ && clang::clang_getCXXAccessSpecifier(*ch) == clang::CX_CXXPublic;
        put(out, { c: b, public_: pub, virtual_: clang::clang_isVirtualBase(*ch) != 0 });
        all_bases(b, pub, out, depth + 1);
    }
}

// class c's casts: as_B for each public base B (a handle borrowing the object, or a B& for a class
// Volt holds by value), and on each base with virtual methods as_C (dynamic_cast: null when the
// object isn't a C)
attach fn casts(this: cpp_gen&, c: clang::CXCursor, vn: str, q: str) -> void {
    var bases: std::vec<base_path> = {};
    all_bases(c, true, &bases, 0);
    var done: std::map<str, bool> = {};
    for (i) in 0..bases.len {
        val bp = *bases.at(i);
        val bq = cpp_qual(bp.c);
        if (!bp.public_ || done.get(bq.as_str()) != null) {
            continue;
        }
        done.put(this.c.intern(copy bq), true);
        // the object has that base once: by one path, or by virtual inheritance however many
        var plain = 0;
        var virt_ = 0;
        for (j) in 0..bases.len {
            if (cpp_qual(bases.at(j).c).as_str() == bq.as_str()) {
                if (bases.at(j).virtual_) {
                    virt_ = 1;
                } else {
                    plain += 1;
                }
            }
        }
        val btr = this.traits.get(bq.as_str()) ?? continue;
        val bvt = S(*(this.classes.get(bq.as_str()) ?? continue));
        if (plain + virt_ > 1) {
            this.line(fmt2("// (no {}::as_ cast to {}: it's that base more than once)", S(q), copy bq).as_str());
            continue;
        }
        val bn = vname(cursor_name(bp.c).as_str());
        if (!this.first_time(fmt2("attach fn as_{}(this: {}&", copy bn, S(vn)).as_str(), "")) {
            this.line(fmt3("// (no {}::as_{} for {}: the name is taken)", S(q), copy bn, copy bq).as_str());
            continue;
        }
        if (btr->trivial) {
            this.line(fmt3("attach fn as_{}(this: {}&) -> {}& {{", copy bn, S(vn), copy bvt).as_str());
            this.line(fmt4("    return @cpp<{}&>(\"static_cast<::{} &>(volt_cpp_obj<::{}>({{0}}))\", this.cpp);", copy bvt, copy bq, S(q), S("")).as_str());
            this.line("}");
            continue;
        }
        this.line(fmt3("attach fn as_{}(this: {}&) -> {} {{", copy bn, S(vn), copy bvt).as_str());
        this.line(fmt3("    return {{ cpp: @cpp<void*>(\"static_cast<::{} *>(&volt_cpp_obj<::{}>({{0}}))\", this.cpp), borrowed: true }};", copy bq, S(q), S("")).as_str());
        this.line("}");
        if (btr->polymorphic && this.first_time(fmt2("attach fn as_{}(this: {}&", vname(cursor_name(c).as_str()), copy bvt).as_str(), "")) {
            this.line(fmt3("attach fn as_{}(this: {}&) -> {}? {{", vname(cursor_name(c).as_str()), copy bvt, S(vn)).as_str());
            this.line(fmt2("    val p = @cpp<void*>(\"volt_cpp_down<::{}>(&volt_cpp_obj<::{}>({{0}}))\", this.cpp);", S(q), copy bq).as_str());
            this.line("    if (p == null) {");
            this.line("        return null;");
            this.line("    }");
            this.line(fmt("    val h: {} = {{ cpp: p, borrowed: true }};", S(vn)).as_str());
            this.line("    return h;");
            this.line("}");
        }
    }
}

// a field's getter (of the same name) and set_ method; at: the field, in a C++ expression ({0}: the
// object's handle)
attach fn field_accessors(this: cpp_gen&, f: clang::CXCursor, vn: str, at: str) -> void {
    val none: std::vec<str> = {};
    val ft = clang::clang_getCursorType(f);
    if (clang::clang_Cursor_isBitField(f) != 0 || ft.kind == clang::CXType_LValueReference || ft.kind == clang::CXType_RValueReference) {
        return;
    }
    val fv = vname(cursor_name(f).as_str());
    var r = this.result(ft, &none) ?? return;
    // the getter gives a copy of it
    if (this.copies_out(ft) && this.first_time(fmt2("attach fn {}(this: {}&", copy fv, S(vn)).as_str(), "")) {
        this.fn_text("", fmt3("attach fn {}(this: {}&) -> {}", copy fv, S(vn), copy r.vty).as_str(), &r, at, ", this.cpp", "");
    }
    if (!this.assignable(ft)) {
        return;
    }
    val a = this.param(ft, "v", 1, &none) ?? return;
    if (this.first_time(fmt2("attach fn set_{}(this: {}&", copy fv, S(vn)).as_str(), fmt(",{}", copy a.vty).as_str())) {
        this.line(fmt3("attach fn set_{}(this: {}&, v: {}) -> void {{", copy fv, S(vn), copy a.vty).as_str());
        this.line(fmt3("    @cpp<void>(\"{} = {}\", this.cpp, {});", S(at), copy a.cpp, copy a.pass).as_str());
        this.line("}");
    }
}

// the public methods of a class held by handle (obj: the object, in a C++ expression)
attach fn class_methods(this: cpp_gen&, c: clang::CXCursor, vn: str, q: str, obj: str) -> void {
    val none: std::vec<str> = {};
    this.members(c, vn, q, obj, "this.cpp", "", "", &none, q);
}

// a type's word in a method name: to_i32, to_string, to_Counter
fn type_word(vty: str) -> std::string {
    var at: usize = 0;
    var i: usize = 0;
    while (i + 1 < vty.len) {
        if (vty[i] == ':' && vty[i + 1] == ':') {
            at = i + 2;
        }
        i += 1;
    }
    var out: std::string = {};
    for (ch) in vty[at..vty.len] {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            out.push(ch);
        } else if (out.len() > 0 && ch != '>') {
            out.push('_');
        }
    }
    return out;
}

// a class's public methods (operators by op_ names, operator T() as to_T(), operator= as assign),
// method templates (generic methods) and static data members (T::name(), T::set_name(v)). obj is
// the object in a C++ expression, self_arg what the Volt method passes for it; self_ty and cpp_self
// the class in Volt and C++; gen, extra and tp a class template's generics
attach fn members(this: cpp_gen&, c: clang::CXCursor, self_ty: str, cpp_self: str, obj: str, self_arg: str, gen: str, extra: str, tp: std::vec<str>&, q: str) -> void {
    val outer_gen = copy this.class_gen;
    this.class_gen = S(gen);
    this.member_list(c, self_ty, cpp_self, obj, self_arg, gen, extra, tp, q);
    this.class_gen = outer_gen;
}

attach fn member_list(this: cpp_gen&, c: clang::CXCursor, self_ty: str, cpp_self: str, obj: str, self_arg: str, gen: str, extra: str, tp: std::vec<str>&, q: str) -> void {
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (!is_public(*ch)) {
            continue;
        }
        if (k == clang::CXCursor_VarDecl) {
            if (gen.len == 0) {
                this.static_member(*ch, self_ty, cpp_self);
            }
            continue;
        }
        var tps: std::vec<std::string> = {};
        if (k == clang::CXCursor_FunctionTemplate) {
            // a method template (not in a class template: one generic list a fn)
            if (gen.len > 0 || clang::clang_getTemplateCursorKind(*ch) != clang::CXCursor_CXXMethod) {
                continue;
            }
            val got = template_params(*ch);
            if (got == null || constrained(*ch)) {
                // the Volt name as for any method (operators by their op_ names)
                val cn = cursor_name(*ch);
                var pn = vname(cn.as_str());
                if (starts_with(cn.as_str(), "operator")) {
                    pn = S(op_name(cn.as_str(), param_count(*ch) + 1) ?? continue);
                }
                if (!is_static_cursor(*ch)) {
                    this.per_use(fmt2("attach fn {}(this: {}&", move pn, S(self_ty)).as_str(), fmt2("{}.{}(", S(obj), copy cn).as_str(), true);
                } else {
                    this.per_use(fmt2("attach fn {}(static this: {}", move pn, S(self_ty)).as_str(), fmt2("{}::{}(", S(cpp_self), copy cn).as_str(), false);
                }
                continue;
            }
            tps = got ?? continue;
        } else if (k != clang::CXCursor_CXXMethod && k != clang::CXCursor_ConversionFunction) {
            continue;
        }
        if (clang::clang_CXXMethod_isDeleted(*ch) != 0) {
            continue;
        }
        val mn = cursor_name(*ch);
        val is_static = clang::clang_CXXMethod_isStatic(*ch) != 0;
        var vn_m = vname(mn.as_str());
        var callee = copy mn;
        var my_gen = S(gen);
        var my_extra = S(extra);
        var my_tp = copy *tp;
        if (tps.len > 0) {
            my_gen = generics_text(&tps);
            my_extra = extra_types(&tps);
            my_tp = str_views(&tps);
            callee = cpp_template_ref(mn.as_str(), tps.len);
        }
        var ret = this.result(clang::clang_getCursorResultType(*ch), &my_tp);
        if (k == clang::CXCursor_ConversionFunction) {
            // operator T(): to_T(), called by its name (an explicit one too); not in a class
            // template, where its type is the template's
            if (gen.len > 0) {
                continue;
            }
            if (ret) {
                vn_m = fmt("to_{}", type_word(ret.vty.as_str()));
            } else {
                continue;
            }
            callee = fmt("operator {}", canon(clang::clang_getCursorResultType(*ch)));
        } else if (starts_with(mn.as_str(), "operator")) {
            if (is_static) {
                continue;
            }
            vn_m = S(op_name(mn.as_str(), param_count(*ch) + 1) ?? continue);
            if (vn_m.as_str() == "assign") {
                // what it returns (the object again) isn't needed
                ret = { vty: S("void") };
            }
        }
        val what = fmt2("{}::{}", S(q), copy mn);
        if (is_static) {
            val head = fmt2("attach fn {}(static this: {}", copy vn_m, S(self_ty));
            this.callable(my_gen.as_str(), head.as_str(), true, *ch, ret, fmt2("{}::{}(", S(cpp_self), copy callee).as_str(), null, my_extra.as_str(), &my_tp, what.as_str());
        } else {
            val head = fmt2("attach fn {}(this: {}&", copy vn_m, S(self_ty));
            this.callable(my_gen.as_str(), head.as_str(), true, *ch, ret, fmt2("{}.{}(", S(obj), copy callee).as_str(), self_arg, my_extra.as_str(), &my_tp, what.as_str());
        }
    }
}

// a static data member: T::name() (a copy of it), and T::set_name(v) when it can be assigned
attach fn static_member(this: cpp_gen&, v: clang::CXCursor, self_ty: str, cpp_self: str) -> void {
    val none: std::vec<str> = {};
    val vt = clang::clang_getCursorType(v);
    val name = cursor_name(v);
    val vn = vname(name.as_str());
    val at = fmt2("{}::{}", S(cpp_self), copy name);
    var r = this.result(vt, &none) ?? return;
    if (this.copies_out(vt) && this.first_time(fmt2("attach fn {}(static this: {}", copy vn, S(self_ty)).as_str(), "")) {
        this.fn_text("", fmt3("attach fn {}(static this: {}) -> {}", copy vn, S(self_ty), copy r.vty).as_str(), &r, at.as_str(), "", "");
    }
    if (!this.assignable(vt)) {
        return;
    }
    val a = this.param(vt, "v", 0, &none) ?? return;
    if (this.first_time(fmt2("attach fn set_{}(static this: {}", copy vn, S(self_ty)).as_str(), fmt(",{}", copy a.vty).as_str())) {
        this.line(fmt3("attach fn set_{}(static this: {}, v: {}) -> void {{", copy vn, S(self_ty), copy a.vty).as_str());
        this.line(fmt3("    @cpp<void>(\"{} = {}\", {});", copy at, copy a.cpp, copy a.pass).as_str());
        this.line("}");
    }
}

// can Volt lay out class template c (as class() does): public fields only, of types it can use (a
// class held by handle isn't laid out as C++ lays it out), no bases, no virtual methods
attach fn template_ok(this: cpp_gen&, c: clang::CXCursor) -> bool {
    val tps = template_params(c) ?? return false;
    val tp = str_views(&tps);
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_CXXBaseSpecifier || (k == clang::CXCursor_CXXMethod && clang::clang_CXXMethod_isVirtual(*ch) != 0)) {
            return false;
        }
        if (k == clang::CXCursor_FieldDecl) {
            val ft = clang::clang_getCursorType(*ch);
            if (!is_public(*ch) || this.handle_of(ft) != null || this.vtype(ft, &tp) == null) {
                return false;
            }
        }
    }
    return true;
}

// leave out (of classes and templates) what can't be declared, before anything refers to it: a
// class template Volt can't lay out (template_ok), and a class held by value whose layout it can't
// copy (class_struct); until nothing more goes, since one going can take others with it
attach fn prune(this: cpp_gen&) -> void {
    loop {
        var gone: std::vec<str> = {};
        for (e) in this.templates.iter() {
            val c = *(this.cursors.get(*e.key) ?? continue);
            if (!this.template_ok(c)) {
                put(&gone, *e.key);
            }
        }
        for (q&) in gone.items() {
            this.templates.remove(*q);
        }
        var gone_classes: std::vec<str> = {};
        for (e) in this.classes.iter() {
            val tr = this.traits.get(*e.key) ?? continue;
            if (!tr->trivial) {
                continue;
            }
            val c = *(this.cursors.get(*e.key) ?? continue);
            // a dry run: written, then taken back out
            val start = this.out.len();
            val ok = this.class_struct(c, last_part(*e.value, "").as_str(), *e.key);
            this.out.bytes.len = start;
            if (!ok) {
                put(&gone_classes, *e.key);
            }
        }
        for (q&) in gone_classes.items() {
            this.classes.remove(*q);
        }
        if (gone.len == 0 && gone_classes.len == 0) {
            break;
        }
    }
}

// the roots of the libraries the use names from the include path (not local files, not the C++
// standard library's): for each, the file it resolved to, then its directory as named ("re2/" of
// re2/re2.h: every file under /usr/include/re2/), or the file alone when it has none
attach fn library_roots(this: cpp_gen&, headers: std::vec<std::string>&, tu: clang_tu&) -> void {
    val files = tu.included_files();
    for (h&) in headers.items() {
        val name = h.as_str();
        // the standard library's headers name no directory and no extension: <vector>, <string>
        var has_dot = false;
        var slash: usize? = null;
        for (i) in 0..name.len {
            if (name[i] == '.') {
                has_dot = true;
            }
            if (name[i] == '/' && slash == null) {
                slash = i;
            }
        }
        if (!has_dot) {
            continue;
        }
        val tail = fmt("/{}", S(name));
        for (f&) in files.items() {
            if (!ends_with(f.as_str(), tail.as_str())) {
                continue;
            }
            if (slash) {
                // /usr/include/ + re2/
                put(&this.roots, S(f.as_str()[0..f.len() - name.len + slash + 1]));
            } else {
                put(&this.roots, copy *f);
            }
            break;
        }
    }
}

// what clang says of each class, from a second parse of the same headers with these appended:
//     constexpr bool t0 = __is_trivially_copyable(::geo::Shape); (d0, c0, a0, n0, p0, f0, v0, e0, m0 likewise)
// A class it can't answer for is held by handle, and Volt neither makes, copies nor assigns one.
// ponytail: the second parse reads every header again (<string>, <vector>: about twice the
// import's time); a precompiled preamble with clang_reparseTranslationUnit if that ever matters
attach fn probe(this: cpp_gen&, src: str, args: std::vec<str>&) -> void {
    var names: std::vec<str> = {};
    var text = S(src);
    text.append("#include <exception>\n#include <type_traits>\nnamespace volt_probe {\n");
    for (e) in this.classes.iter() {
        val i = unum(@cast<u64>(names.len));
        val q = S(*e.key);
        text.append(fmt2("constexpr bool t{} = __is_trivially_copyable(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("constexpr bool d{} = __is_destructible(::{});\n", copy i, copy q).as_str());
        text.append(fmt3("constexpr bool c{} = __is_constructible(::{}, const ::{} &);\n", copy i, copy q, copy q).as_str());
        text.append(fmt3("constexpr bool a{} = __is_assignable(::{} &, ::{} &&);\n", copy i, copy q, copy q).as_str());
        text.append(fmt2("constexpr bool n{} = __is_constructible(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("constexpr bool p{} = __is_polymorphic(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("constexpr bool f{} = __is_final(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("constexpr bool v{} = __has_virtual_destructor(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("constexpr bool e{} = std::is_convertible<::{} *, const std::exception *>::value;\n", copy i, copy q).as_str());
        text.append(fmt3("constexpr bool m{} = __is_constructible(::{}, ::{} &&);\n", copy i, copy q, copy q).as_str());
        put(&names, *e.key);
        this.traits.put(*e.key, {});
    }
    text.append("}\n");
    if (names.len == 0) {
        return;
    }
    var tu = clang_parse("volt_cpp_probe.cpp", text.as_str(), args);
    if (tu.tu == null) {
        return;
    }
    for (ns&) in children(tu.root()).items() {
        if (clang::clang_getCursorKind(*ns) != clang::CXCursor_Namespace || cursor_name(*ns).as_str() != "volt_probe") {
            continue;
        }
        for (v&) in children(*ns).items() {
            val vname_ = cursor_name(*v);
            if (vname_.len() < 2) {
                continue;
            }
            val i = hole_index(vname_.as_str()[1..vname_.len()]) ?? continue;
            if (i >= names.len) {
                continue;
            }
            var yes = false;
            val ev = clang::clang_Cursor_Evaluate(*v);
            if (ev != null) {
                yes = clang::clang_EvalResult_getKind(ev) == clang::CXEval_Int && clang::clang_EvalResult_getAsInt(ev) != 0;
                clang::clang_EvalResult_dispose(ev);
            }
            val tr = this.traits.get(*names.at(i)) ?? continue;
            val which = vname_.as_str()[0..1];
            if (which == "t") {
                tr->trivial = yes;
            } else if (which == "d") {
                tr->destructible = yes;
            } else if (which == "c") {
                tr->copyable = yes;
            } else if (which == "a") {
                tr->assignable = yes;
            } else if (which == "n") {
                tr->defaults = yes;
            } else if (which == "p") {
                tr->polymorphic = yes;
            } else if (which == "f") {
                tr->final_ = yes;
            } else if (which == "v") {
                tr->vdtor = yes;
            } else if (which == "m") {
                tr->movable = yes;
            } else {
                tr->exception = yes;
            }
        }
    }
}

// ---------- Volt types subclassing C++ classes ----------

// how one parameter of a virtual method crosses from C++ to the Volt method overriding it (aN is the
// parameter on both sides)
struct virt_arg {
    vty: std::string;    // its type in the trait's fn
    thunk: std::string;  // its type in the thunk: what C++ passes
    cpp_ty: std::string; // that, in C++ (in the thunk's function pointer type)
    cpp: std::string;    // the C++ expression passing it
    arg: std::string;    // the Volt expression the thunk passes on
    handle: std::string = {}; // a class held by handle: its Volt type (the thunk makes a handle of
                              // the object, and empties it after the call)
}

// how a virtual method's result comes back from the Volt method overriding it
struct virt_ret {
    vty: std::string;
    cpp_ty: std::string;    // the thunk's result in C++ (void when it writes to out)
    out: u8 = 0;            // 1: a class Volt holds by value, written to *out; 2: a std::string, assigned to *out
    cast: std::string = {}; // the C++ type it's cast back to (an enum from its tag)
}

// a virtual method a Volt type can override (the class's own, or inherited)
struct virt {
    m: clang::CXCursor;
    pure: bool;
    private_: bool; // private, or inherited through a base that isn't public: a subclass can't call it
}

// a C++ type as C++ spells it anywhere (qualified)
fn canon(t: clang::CXType) -> std::string {
    return type_spelling(clang::clang_getCanonicalType(t));
}

// what tells two virtual methods apart: the name, the parameters' types and const
fn virt_key(m: clang::CXCursor) -> std::string {
    var k = cursor_name(m);
    k.push('(');
    for (ch&) in params_of(m).items() {
        k.append(canon(clang::clang_getCursorType(*ch)).as_str());
        k.push(',');
    }
    k.push(')');
    if (clang::clang_CXXMethod_isConst(m) != 0) {
        k.append("const");
    }
    return k;
}

fn is_final(m: clang::CXCursor) -> bool {
    for (ch&) in children(m).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_CXXFinalAttr) {
            return true;
        }
    }
    return false;
}

// the virtual methods of class c and its bases, the most derived declaration of each first (a final
// one is left out: nothing overrides it); public_: c is reached by public inheritance
attach fn virtuals(this: cpp_gen&, c: clang::CXCursor, public_: bool, out: std::vec<virt>&, seen: std::map<str, bool>&, depth: u32) -> void {
    if (depth > 16) {
        return;
    }
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) != clang::CXCursor_CXXMethod || clang::clang_CXXMethod_isVirtual(*ch) == 0) {
            continue;
        }
        val key = this.c.intern(virt_key(*ch));
        if (seen.get(key) != null) {
            continue;
        }
        seen.put(key, true);
        if (!is_final(*ch)) {
            put(out, { m: *ch, pure: clang::clang_CXXMethod_isPureVirtual(*ch) != 0, private_: !public_ || clang::clang_getCXXAccessSpecifier(*ch) == clang::CX_CXXPrivate });
        }
    }
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_CXXBaseSpecifier) {
            val b = clang::clang_getCursorDefinition(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(clang::clang_getCursorType(*ch))));
            if (clang::clang_Cursor_isNull(b) == 0) {
                this.virtuals(b, public_ && clang::clang_getCXXAccessSpecifier(*ch) == clang::CX_CXXPublic, out, seen, depth + 1);
            }
        }
    }
}

// parameter i (of type t) of a virtual method, from C++ to Volt: text (a str view), numbers, enums and
// pointers as they are, a class Volt holds by value by its address, one held by handle as a handle
// to C++'s object (Volt borrows it for the call)
attach fn virt_param(this: cpp_gen&, t: clang::CXType, i: usize) -> virt_arg? {
    val none: std::vec<str> = {};
    val a = fmt("a{}", unum(@cast<u64>(i)));
    // through typedefs (using Ref = T&)
    val ck = clang::clang_getCanonicalType(t).kind;
    if (ck == clang::CXType_RValueReference) {
        return null;
    }
    val is_ref = ck == clang::CXType_LValueReference;
    var base = t;
    if (is_ref) {
        base = clang::clang_getPointeeType(clang::clang_getCanonicalType(t));
    }
    if (!(is_ref && clang::clang_isConstQualifiedType(base) == 0) && (char_text(base, "basic_string") || char_text(base, "basic_string_view"))) {
        return { vty: S("str"), thunk: S("str"), cpp_ty: S("volt_str"), cpp: fmt("volt_cpp_view({})", copy a), arg: copy a };
    }
    val hc = this.handle_of(base);
    if (hc) {
        val vt = this.vtype(base, &none) ?? return null;
        return { vty: fmt("{}&", copy vt), thunk: S("void*"), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: fmt("&h{}", unum(@cast<u64>(i))), handle: copy vt };
    }
    if (is_class(base)) {
        // an imported class (not a std one, nor an instance of a template)
        if (this.traits.get(cpp_qual(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(base))).as_str()) == null) {
            return null;
        }
        val vt = this.vtype(base, &none) ?? return null;
        if (is_ref) {
            return { vty: fmt("{}&", copy vt), thunk: fmt("{}&", copy vt), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: copy a };
        }
        return { vty: copy vt, thunk: fmt("{}&", copy vt), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: fmt("*{}", copy a) };
    }
    if (is_ref) {
        return null;
    }
    val vt = this.vtype(t, &none) ?? return null;
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_Enum) {
        val under = fmt("std::underlying_type_t<{}>", canon(t));
        return { vty: copy vt, thunk: copy vt, cpp_ty: copy under, cpp: fmt2("({}){}", copy under, copy a), arg: copy a };
    }
    return { vty: copy vt, thunk: copy vt, cpp_ty: canon(t), cpp: copy a, arg: copy a };
}

// a virtual method's result, from Volt back to C++: numbers, enums and pointers as they are, a class
// Volt holds by value and a std::string through a pointer to C++'s
attach fn virt_result(this: cpp_gen&, t: clang::CXType) -> virt_ret? {
    val none: std::vec<str> = {};
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind == clang::CXType_Void) {
        return { vty: S("void"), cpp_ty: S("void") };
    }
    if (ct.kind == clang::CXType_LValueReference || ct.kind == clang::CXType_RValueReference) {
        return null;
    }
    if (char_text(t, "basic_string")) {
        return { vty: S("std::string"), cpp_ty: S("void"), out: 2 };
    }
    if (is_class(t)) {
        if (this.handle_of(t) != null || this.traits.get(cpp_qual(clang::clang_getTypeDeclaration(ct)).as_str()) == null) {
            return null;
        }
        return { vty: this.vtype(t, &none) ?? return null, cpp_ty: S("void"), out: 1 };
    }
    val vt = this.vtype(t, &none) ?? return null;
    if (ct.kind == clang::CXType_Enum) {
        return { vty: move vt, cpp_ty: fmt("std::underlying_type_t<{}>", canon(t)), cast: canon(t) };
    }
    return { vty: move vt, cpp_ty: canon(t) };
}

// one overridable virtual method: its C++ and Volt names, parameters and result
struct virt_map {
    m: clang::CXCursor;
    pure: bool;
    cname: std::string;
    vname: std::string;
    names: std::vec<std::string>; // the parameters' Volt names
    args: std::vec<virt_arg>;
    ret: virt_ret;
}

// the virtual methods a Volt type deriving from class c can override (a comment for each one it
// can't); null when no Volt type can derive from c (a pure virtual one has types Volt can't give,
// or there are none)
attach fn virt_maps(this: cpp_gen&, c: clang::CXCursor, q: str, vs: std::vec<virt>&) -> std::vec<virt_map>? {
    var seen: std::map<str, bool> = {};
    this.virtuals(c, true, vs, &seen, 0);
    // the ones Volt can override (a name once: an overload of it stays C++'s)
    var maps: std::vec<virt_map> = {};
    var named: std::map<str, bool> = {};
    for (v&) in vs.items() {
        val mn = cursor_name(v.m);
        if (!v.pure && v.private_) {
            // the subclass couldn't call C++'s own when the Volt type doesn't override it
            this.line(fmt2("// ({}::{} is C++'s own in a Volt type deriving from it: it's private)", S(q), copy mn).as_str());
            continue;
        }
        var ok = !starts_with(mn.as_str(), "operator") && named.get(mn.as_str()) == null && clang::clang_Cursor_isVariadic(v.m) == 0 && clang::clang_Type_getCXXRefQualifier(clang::clang_getCursorType(v.m)) == clang::CXRefQualifier_None;
        var args: std::vec<virt_arg> = {};
        var names: std::vec<std::string> = {};
        if (ok) {
            for (ch&) in params_of(v.m).items() {
                val a = this.virt_param(clang::clang_getCursorType(*ch), args.len);
                if (a) {
                    put(&args, copy a);
                } else {
                    ok = false;
                    break;
                }
                var pn = vname(cursor_name(*ch).as_str());
                if (pn.len() == 0 || pn.as_str() == "self") {
                    pn = fmt("a{}", unum(@cast<u64>(names.len)));
                }
                put(&names, move pn);
            }
        }
        var ret: virt_ret? = null;
        if (ok) {
            ret = this.virt_result(clang::clang_getCursorResultType(v.m));
        }
        if (!ok || ret == null) {
            if (v.pure) {
                this.line(fmt2("// (Volt types can't derive from {}: its pure virtual {} has types Volt can't give)", S(q), copy mn).as_str());
                return null;
            }
            this.line(fmt2("// ({}::{} is C++'s own in a Volt type deriving from it: its types)", S(q), copy mn).as_str());
            continue;
        }
        named.put(this.c.intern(copy mn), true);
        put(&maps, { m: v.m, pure: v.pure, cname: copy mn, vname: vname(mn.as_str()), names: move names, args: move args, ret: ret ?? { vty: {}, cpp_ty: {} } });
    }
    if (maps.len == 0) {
        return null;
    }
    return maps;
}

// how many arguments a list of them, as Volt text, has ("a, f(b, c), g<T>" has 3)
fn args_in(s: str) -> usize {
    if (s.len == 0) {
        return 0;
    }
    var n: usize = 1;
    var depth: i32 = 0;
    var quoted = false;
    var escaped = false;
    for (ch) in s {
        if (escaped) {
            escaped = false;
        } else if (quoted) {
            escaped = ch == '\\';
            quoted = ch != '"';
        } else if (ch == '"') {
            quoted = true;
        } else if (ch == '(' || ch == '<' || ch == '[' || ch == '{') {
            depth += 1;
        } else if (ch == ')' || ch == '>' || ch == ']' || ch == '}') {
            depth -= 1;
        } else if (ch == ',' && depth == 0) {
            n += 1;
        }
    }
    return n;
}

// A Volt type subclassing class c (held by handle, polymorphic, not final, with a virtual
// destructor). On the Volt side: a trait of c's virtual methods (struct vn stands for it in attach
// blocks: @attach_as), T::derive, derived<T>, base_ methods and the protected members. On the C++
// side, a subclass per Volt type, a template over each method's thunk and whether the type has the
// method: an override calls the Volt method directly, or C++'s own (no table, nothing checked at
// run time)
attach fn director(this: cpp_gen&, c: clang::CXCursor, vn: str, q: str, maps: std::vec<virt_map>&, vs: std::vec<virt>&) -> void {
    val none: std::vec<str> = {};
    var dn = S("volt_dir_");
    for (ch) in q {
        if (ch == ':') {
            dn.push('_');
        } else {
            dn.push(ch);
        }
    }
    val bn = fmt("{}_base", copy dn);
    // the trait
    this.line(fmt2("// {}'s virtual methods: a Volt type overrides them in an attach block (attach {} -> T), by", S(q), S(vn)).as_str());
    this.line(fmt("// their own names (the pure ones it has to), and {}::derive makes the C++ object, which holds", S(vn)).as_str());
    this.line("// the Volt value (deleted with it)");
    this.line("@attributes([@closed])");
    this.line(fmt("trait {}_virtuals {{", S(vn)).as_str());
    for (m&) in maps.items() {
        var ps = fmt("this, self: {}&", S(vn));
        for (i) in 0..m.args.len {
            ps.append(fmt2(", {}: {}", copy *m.names.at(i), copy m.args.at(i).vty).as_str());
        }
        if (!m.pure) {
            this.line("    @attributes([@optional])");
        }
        this.line(fmt3("    fn {}({}) -> {};", copy m.vname, move ps, copy m.ret.vty).as_str());
    }
    this.line("}");
    // what the C++ object holds: the Volt value, and its type's id (derived<T> checks it)
    this.line("<T: type>");
    this.line(fmt("struct {}_volt {{", S(vn)).as_str());
    this.line("    tid: u64;");
    this.line("    impl: T;");
    this.line("}");
    // a thunk each: C++ calls it with the Volt side and the object, and it calls the Volt method (the
    // subclass calls only those of the methods the type has)
    for (m&) in maps.items() {
        var ps = S("d: void*, self: void*");
        for (i) in 0..m.args.len {
            ps.append(fmt2(", a{}: {}", unum(@cast<u64>(i)), copy m.args.at(i).thunk).as_str());
        }
        if (m.ret.out != 0) {
            ps.append(", out: void*");
        }
        var rty = copy m.ret.vty;
        if (m.ret.out != 0) {
            rty = S("void");
        }
        this.line("<T: type>");
        this.line(fmt4("fn {}_volt_{}({}) -> {} {{", S(vn), copy m.vname, move ps, move rty).as_str());
        this.depth += 1;
        this.line(fmt2("comptime if (@has_method(T, \"{}\", {}&)) {{", copy m.vname, S(vn)).as_str());
        this.depth += 1;
        this.line(fmt("var me: {} = {{ cpp: self, borrowed: true, volt: d }};", S(vn)).as_str());
        var call = fmt2("@cast<{}_volt<T>*>(d)->impl.{}(&me", S(vn), copy m.vname);
        for (i) in 0..m.args.len {
            val a = m.args.at(i);
            if (a.handle.len() > 0) {
                this.line(fmt3("var h{}: {} = {{ cpp: a{}, borrowed: true }};", unum(@cast<u64>(i)), copy a.handle, unum(@cast<u64>(i))).as_str());
            }
            call.append(", ");
            call.append(a.arg.as_str());
        }
        call.push(')');
        if (m.ret.vty.as_str() == "void") {
            this.line(fmt("{};", move call).as_str());
        } else if (m.ret.out == 1) {
            this.line(fmt2("@write(@cast<{}*>(out), {});", copy m.ret.vty, move call).as_str());
        } else if (m.ret.out == 2) {
            this.line(fmt("val r = {};", move call).as_str());
            this.line("@cpp<void>(\"((std::string *){0})->assign((const char *){1}.ptr, {1}.len)\", out, r.as_str());");
        } else {
            this.line(fmt("return {};", move call).as_str());
        }
        this.depth -= 1;
        this.line("} else {");
        this.line("    @panic(\"C++ called a method the Volt type doesn't have\");");
        this.line("}");
        this.depth -= 1;
        this.line("}");
    }
    // deleting the Volt side (the C++ object's destructor calls it), and making it: a type has to
    // have the pure virtual methods
    this.line("<T: type>");
    this.line(fmt("fn {}_volt_drop(d: void*) -> void {{", S(vn)).as_str());
    this.line(fmt("    val b = @read(@cast<{}_volt<T>*>(d));", S(vn)).as_str());
    this.line("    @cpp<void>(\"std::free({0})\", d);");
    this.line("}");
    this.line("<T: type>");
    this.line(fmt("fn {}_volt_new(impl: T) -> void* {{", S(vn)).as_str());
    this.depth += 1;
    for (m&) in maps.items() {
        if (m.pure) {
            this.line(fmt2("comptime if (!@has_method(T, \"{}\", {}&)) {{", copy m.vname, S(vn)).as_str());
            this.line(fmt3("    @compile_error(\"a Volt type deriving from {} has to override {}, which is pure virtual (in its attach {} -> T block)\");", S(q), copy m.cname, S(vn)).as_str());
            this.line("}");
        }
    }
    this.line(fmt("val p = @cpp<void*>(\"std::malloc({{0}})\", @sizeof({}_volt<T>));", S(vn)).as_str());
    this.line("if (p == null) {");
    this.line("    @panic(\"out of memory\");");
    this.line("}");
    this.line(fmt("@write(@cast<{}_volt<T>*>(p), {{ tid: @typeid(T), impl: move impl }});", S(vn)).as_str());
    this.line("return p;");
    this.depth -= 1;
    this.line("}");
    // T::derive(impl, the constructor's arguments), one each constructor (public or protected): the
    // subclass's template arguments are the drop function, then each method's thunk and whether T
    // has it
    var lead = fmt("volt_d, {}_volt_drop<T>", S(vn));
    var targs = S("{&1}");
    for (k) in 0..maps.len {
        val m = maps.at(k);
        lead.append(fmt3(", {}_volt_{}<T>, @has_method(T, \"{}\", ", S(vn), copy m.vname, copy m.vname).as_str());
        lead.append(fmt("{}&)", S(vn)).as_str());
        targs.append(fmt2(", {{&{}}}, {{={}}}", unum(@cast<u64>(2 + 2 * k)), unum(@cast<u64>(3 + 2 * k))).as_str());
    }
    val cls = fmt2("{}<{}>", copy dn, move targs);
    val made: cpp_ret = { vty: S(vn), way: ret_way::HANDLE, cls: copy cls, up: fmt("::{}", S(q)), pre: fmt("val volt_d = {}_volt_new<T>(move impl);", S(vn)), volt: S("volt_d") };
    val head = fmt("attach fn derive(static this: {}, impl: T", S(vn));
    val make = fmt("{}::make({{0}})(", copy cls);
    var any_ctor = false;
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) != clang::CXCursor_Constructor) {
            continue;
        }
        any_ctor = true;
        if (clang::clang_getCXXAccessSpecifier(*ch) == clang::CX_CXXPrivate || clang::clang_CXXMethod_isDeleted(*ch) != 0 || clang::clang_CXXConstructor_isCopyConstructor(*ch) != 0 || clang::clang_CXXConstructor_isMoveConstructor(*ch) != 0) {
            continue;
        }
        this.callable("<T: type>", head.as_str(), true, *ch, copy made, make.as_str(), lead.as_str(), "", &none, fmt("{}'s constructor", S(q)).as_str());
    }
    if (!any_ctor) {
        this.fn_text("<T: type>", fmt2("{}) -> {}", copy head, S(vn)).as_str(), &made, fmt("{})", copy make).as_str(), fmt(", {}", copy lead).as_str(), "");
    }
    // the Volt value a derived object holds, when it's a T: the handle derive made (or one a thunk
    // gives a method) knows it; for another, only RTTI can tell (null without it)
    this.line("<T: type>");
    this.line(fmt("attach fn derived(this: {}&) -> T* {{", S(vn)).as_str());
    this.depth += 1;
    this.line("var d = this.volt;");
    this.line("if (d == null) {");
    this.line(fmt2("    d = @cpp<void*>(\"volt_dir_block<{}, ::{}>({{0}})\", this.cpp);", copy bn, S(q)).as_str());
    this.line("}");
    this.line("if (d == null) {");
    this.line("    return null;");
    this.line("}");
    this.line(fmt("val b = @cast<{}_volt<T>*>(d);", S(vn)).as_str());
    this.line("if (b->tid != @typeid(T)) {");
    this.line("    return null;");
    this.line("}");
    this.line("return &b->impl;");
    this.depth -= 1;
    this.line("}");
    // base_m: C++'s own m (what a Volt method overriding it can call); a protected one through the
    // subclass. The protected methods too: an object derive made (this.volt) is one of the subclass,
    // another is when RTTI says so
    var cpp = S("");
    val obj = fmt("volt_cpp_obj<::{}>({{0}})", S(q));
    val dir = fmt2("volt_dir_of<{}, ::{}>({{0}}, {{1}})", copy bn, S(q));
    for (v&) in vs.items() {
        val mn = cursor_name(v.m);
        val acc = clang::clang_getCXXAccessSpecifier(v.m);
        if (v.pure || v.private_ || starts_with(mn.as_str(), "operator")) {
            continue;
        }
        val ret = this.result(clang::clang_getCursorResultType(v.m), &none);
        val h = fmt2("attach fn base_{}(this: {}&", vname(mn.as_str()), S(vn));
        if (acc == clang::CX_CXXPublic) {
            this.callable("", h.as_str(), true, v.m, ret, fmt3("{}.{}::{}(", copy obj, S(q), copy mn).as_str(), "this.cpp", "", &none, fmt2("{}::{}", S(q), copy mn).as_str());
        } else {
            this.callable("", h.as_str(), true, v.m, ret, fmt2("{}.volt_base_{}(", copy dir, copy mn).as_str(), "this.cpp, this.volt", "", &none, fmt2("{}::{}", S(q), copy mn).as_str());
            cpp.append(fmt2("    template <class... A>\n    decltype(auto) volt_base_{}(A &&...a) {{ return ::{}::", copy mn, S(q)).as_str());
            cpp.append(fmt("{}(std::forward<A>(a)...); }\n", copy mn).as_str());
        }
    }
    // a protected field is reached through a pointer to it as a member (which the subclass can
    // take), so on any object
    var pnames: std::map<str, bool> = {};
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (clang::clang_getCXXAccessSpecifier(*ch) != clang::CX_CXXProtected) {
            continue;
        }
        val mn = cursor_name(*ch);
        if (k == clang::CXCursor_CXXMethod && clang::clang_CXXMethod_isStatic(*ch) == 0 && clang::clang_CXXMethod_isDeleted(*ch) == 0 && !starts_with(mn.as_str(), "operator")) {
            val ret = this.result(clang::clang_getCursorResultType(*ch), &none);
            this.callable("", fmt2("attach fn {}(this: {}&", vname(mn.as_str()), S(vn)).as_str(), true, *ch, ret, fmt2("{}.volt_p_{}(", copy dir, copy mn).as_str(), "this.cpp, this.volt", "", &none, fmt2("{}::{}", S(q), copy mn).as_str());
            if (pnames.get(mn.as_str()) == null) {
                pnames.put(this.c.intern(copy mn), true);
                cpp.append(fmt2("    template <class... A>\n    decltype(auto) volt_p_{}(A &&...a) {{ return this->{}(std::forward<A>(a)...); }}\n", copy mn, copy mn).as_str());
            }
        } else if (k == clang::CXCursor_FieldDecl && clang::clang_Cursor_isBitField(*ch) == 0) {
            this.field_accessors(*ch, vn, fmt3("({}.*{}::volt_pf_{}())", copy obj, copy bn, copy mn).as_str());
            cpp.append(fmt2("    static auto volt_pf_{}() {{ return &{}::", copy mn, copy bn).as_str());
            cpp.append(fmt("{}; }\n", copy mn).as_str());
        }
    }
    // the C++ subclasses: what each has (the Volt side, the way to the protected members), then one
    // per Volt type
    var text = fmt("// Volt's subclasses of {} (derive): what every one has, the Volt side and the protected\n// members\n", S(q));
    text.append(fmt2("struct {} : ::{} {{\n", copy bn, S(q)).as_str());
    text.append("    void *volt_d; // the Volt side: the Volt value and its type's id\n");
    text.append(fmt3("    template <class... A>\n    explicit {}(void *d, A &&...a) : ::{}(std::forward<A>(a)...), volt_d(d) {{}}\n", copy bn, S(q), S("")).as_str());
    text.append(fmt("    void *volt_self() const {{ return (void *)static_cast<const ::{} *>(this); }}\n", S(q)).as_str());
    text.append(cpp.as_str());
    text.append("};\n\n");
    text.append("// one per Volt type: FD deletes the Volt side, Fk is method k's thunk and Ok whether the type\n// has it (else the method is C++'s own)\n");
    text.append("template <auto FD");
    for (k) in 0..maps.len {
        text.append(fmt2(", auto F{}, bool O{}", unum(@cast<u64>(k)), unum(@cast<u64>(k))).as_str());
    }
    text.append(">\n");
    text.append(fmt2("struct {} final : {} {{\n", copy dn, copy bn).as_str());
    text.append(fmt2("    using {}::{};\n", copy bn, copy bn).as_str());
    text.append(fmt2("    struct volt_make {{\n        void *d;\n        template <class... A>\n        {} operator()(A &&...a) const {{ return {}(d, std::forward<A>(a)...); }}\n    }};\n", copy dn, copy dn).as_str());
    text.append("    static volt_make make(void *d) { return {d}; }\n");
    text.append(fmt("    ~{}() override {{ ((void (*)(void *))FD)(volt_d); }}\n", copy dn).as_str());
    for (k) in 0..maps.len {
        val m = maps.at(k);
        val rt = canon(clang::clang_getCursorResultType(m.m));
        var params: std::string = {};
        var fty = S("void *, void *");
        var pass = S("volt_d, volt_self()");
        var base = S("");
        var i: usize = 0;
        for (ch&) in params_of(m.m).items() {
            val pt = clang::clang_getCursorType(*ch);
            if (i > 0) {
                params.append(", ");
                base.append(", ");
            }
            params.append(fmt2("volt_id<{}> a{}", canon(pt), unum(@cast<u64>(i))).as_str());
            if (clang::clang_getCanonicalType(pt).kind == clang::CXType_LValueReference) {
                base.append(fmt("a{}", unum(@cast<u64>(i))).as_str());
            } else {
                base.append(fmt("std::move(a{})", unum(@cast<u64>(i))).as_str());
            }
            fty.append(", ");
            fty.append(m.args.at(i).cpp_ty.as_str());
            pass.append(", ");
            pass.append(m.args.at(i).cpp.as_str());
            i += 1;
        }
        if (m.ret.out != 0) {
            fty.append(", void *");
        }
        var quals = S("");
        if (clang::clang_CXXMethod_isConst(m.m) != 0) {
            quals.append(" const");
        }
        if (!may_throw(m.m)) {
            quals.append(" noexcept");
        }
        val ks = unum(@cast<u64>(k));
        text.append(fmt4("    volt_id<{}> {}({}){} override {{\n", copy rt, copy m.cname, move params, move quals).as_str());
        text.append(fmt("        if constexpr (O{}) {{\n", copy ks).as_str());
        val f = fmt3("(({} (*)({}))F{})", copy m.ret.cpp_ty, move fty, copy ks);
        if (m.ret.out == 1) {
            text.append(fmt3("            alignas({}) unsigned char volt_r[sizeof({})];\n            {}(", copy rt, copy rt, copy f).as_str());
            text.append(fmt("{}, volt_r);\n", copy pass).as_str());
            text.append(fmt("            return *std::launder(reinterpret_cast<{} *>(volt_r));\n", copy rt).as_str());
        } else if (m.ret.out == 2) {
            text.append(fmt2("            std::string volt_r;\n            {}({}, &volt_r);\n            return volt_r;\n", copy f, copy pass).as_str());
        } else if (m.ret.vty.as_str() == "void") {
            text.append(fmt2("            {}({});\n", copy f, copy pass).as_str());
        } else if (m.ret.cast.len() > 0) {
            text.append(fmt3("            return ({}){}({});\n", copy m.ret.cast, copy f, copy pass).as_str());
        } else {
            text.append(fmt2("            return {}({});\n", copy f, copy pass).as_str());
        }
        text.append("        } else {\n");
        if (m.pure) {
            text.append(fmt2("            volt_cpp_throw(\"{}::{} is pure virtual, and the Volt type doesn't override it\");\n", S(q), copy m.cname).as_str());
        } else {
            text.append(fmt3("            return ::{}::{}({});\n", S(q), copy m.cname, move base).as_str());
        }
        text.append("        }\n    }\n");
    }
    text.append("};\n");
    put(&this.c.cpp_decl_names, move dn);
    put(&this.c.cpp_decls, move text);
}

// ---------- enums ----------

attach fn enum_decl(this: cpp_gen&, c: clang::CXCursor) -> void {
    val name = cursor_name(c);
    if (name.len() == 0) {
        return;
    }
    val none: std::vec<str> = {};
    val tag = this.vtype(clang::clang_getEnumDeclIntegerType(c), &none) ?? S("i32");
    var vn = vname(name.as_str());
    val path = this.enums.get(cpp_qual(c).as_str());
    if (path) {
        vn = last_part(*path, name.as_str());
    }
    this.line(fmt2("enum {}: {} {{", copy vn, move tag).as_str());
    this.depth += 1;
    var names: std::vec<std::string> = {};
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_EnumConstantDecl) {
            val cn = vname(cursor_name(*ch).as_str());
            this.line(fmt2("{} = {},", copy cn, num(@cast<i128>(clang::clang_getEnumConstantDeclValue(*ch)))).as_str());
            put(&names, move cn);
        }
    }
    this.depth -= 1;
    this.line("}");
    // an unscoped enum's names are in the enclosing namespace too (one inside a class: the class's,
    // so only through the enum here: Outer_Mode::Low)
    val parent = clang::clang_getCursorKind(clang::clang_getCursorSemanticParent(c));
    if (clang::clang_EnumDecl_isScoped(c) == 0 && parent != clang::CXCursor_ClassDecl && parent != clang::CXCursor_StructDecl) {
        for (cn&) in names.items() {
            this.line(fmt4("val {}: {} = {}::{};", copy *cn, copy vn, copy vn, copy *cn).as_str());
        }
    }
}

// ---------- walking the headers ----------

// the classes, enums and class templates the headers declare (outside system headers), with the
// Volt path each gets inside the import's namespace
attach fn scan(this: cpp_gen&, c: clang::CXCursor, vpath: str) -> void {
    for (ch&) in children(c).items() {
        if (this.skip(*ch)) {
            continue;
        }
        val k = clang::clang_getCursorKind(*ch);
        val name = cursor_name(*ch);
        if (name.len() == 0) {
            continue;
        }
        // a class's own private and protected types can't be named outside it
        val acc = clang::clang_getCXXAccessSpecifier(*ch);
        if (acc == clang::CX_CXXPrivate || acc == clang::CX_CXXProtected) {
            continue;
        }
        var p = S(vpath);
        p.append(vname(name.as_str()).as_str());
        val q = this.c.intern(cpp_qual(*ch));
        if (k == clang::CXCursor_Namespace) {
            if (clang::clang_Cursor_isInlineNamespace(*ch) != 0) {
                this.scan(*ch, vpath);
                continue;
            }
            p.append("::");
            this.scan(*ch, p.as_str());
        } else if ((k == clang::CXCursor_ClassDecl || k == clang::CXCursor_StructDecl) && clang::clang_isCursorDefinition(*ch) != 0) {
            // the types inside it: Outer_Inner (Volt has no types inside types)
            var inner = copy p;
            inner.push('_');
            this.scan(*ch, inner.as_str());
            this.classes.put(q, this.c.intern(move p));
            this.cursors.put(q, *ch);
        } else if (k == clang::CXCursor_ClassTemplate && clang::clang_isCursorDefinition(*ch) != 0) {
            // its definition (a forward declaration has no fields or bases to tell by)
            this.templates.put(q, this.c.intern(move p));
            this.cursors.put(q, *ch);
        } else if (k == clang::CXCursor_EnumDecl) {
            this.enums.put(q, this.c.intern(move p));
        }
    }
}

// the Volt source for the declarations under c
attach fn emit(this: cpp_gen&, c: clang::CXCursor) -> void {
    for (ch&) in children(c).items() {
        if (this.skip(*ch)) {
            continue;
        }
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_Namespace) {
            val name = cursor_name(*ch);
            if (name.len() == 0) {
                continue;
            }
            // an inline namespace (a library's ABI version) is its parent's in C++ too
            if (clang::clang_Cursor_isInlineNamespace(*ch) != 0) {
                this.emit(*ch);
                continue;
            }
            this.line(fmt("namespace {} {{", vname(name.as_str())).as_str());
            this.depth += 1;
            val outer = this.scope.len();
            this.scope.append("::");
            this.scope.append(name.as_str());
            this.emit(*ch);
            this.scope.bytes.len = outer;
            this.depth -= 1;
            this.line("}");
        } else if ((k == clang::CXCursor_ClassDecl || k == clang::CXCursor_StructDecl) && clang::clang_isCursorDefinition(*ch) != 0) {
            this.class(*ch, null);
            this.nested(*ch);
        } else if (k == clang::CXCursor_VarDecl) {
            this.constant(*ch);
        } else if (k == clang::CXCursor_ClassTemplate && clang::clang_isCursorDefinition(*ch) != 0 && this.templates.get(cpp_qual(*ch).as_str()) != null) {
            // one whose parameters all have defaults has nothing for Volt's generics (and one
            // prune left out isn't declared)
            val tps = template_params(*ch);
            var n: usize = 0;
            if (tps) {
                n = tps.len;
            }
            if (n > 0) {
                this.class(*ch, copy tps);
            }
        } else if (k == clang::CXCursor_EnumDecl) {
            this.enum_decl(*ch);
        } else if ((k == clang::CXCursor_FunctionDecl || k == clang::CXCursor_FunctionTemplate) && this.first_decl(*ch)) {
            if (k == clang::CXCursor_FunctionDecl) {
                val none: std::vec<std::string> = {};
                this.free_fn(*ch, &none);
            } else {
                val tps = template_params(*ch);
                var typed = false;
                if (tps) {
                    if (!constrained(*ch)) {
                        this.free_fn(*ch, &tps);
                        typed = true;
                    }
                }
                if (!typed) {
                    // non-type, template-template or constrained parameters: per use (an operator
                    // by its op_ name, as free_fn has it)
                    val cn = cursor_name(*ch);
                    var pn = vname(cn.as_str());
                    var named = true;
                    if (starts_with(cn.as_str(), "operator")) {
                        val on = op_name(cn.as_str(), param_count(*ch));
                        if (on) {
                            pn = S(on);
                        } else {
                            named = false;
                        }
                    }
                    if (named) {
                        this.per_use(fmt("fn {}(", move pn).as_str(), fmt("{}(", cpp_qual(*ch)).as_str(), false);
                    }
                }
            }
        } else if (k == clang::CXCursor_MacroDefinition && clang::clang_Cursor_isMacroFunctionLike(*ch) != 0 && clang::clang_Cursor_isMacroBuiltin(*ch) == 0 && this.scope.len() == 0 && !this.skip(*ch)) {
            // a function-like macro: each call is expanded where it's made
            val mn = cursor_name(*ch);
            this.per_use(fmt("fn {}(", vname(mn.as_str())).as_str(), fmt("#{}(", copy mn).as_str(), false);
        }
    }
}

// does template c constrain its parameters (a requires clause, or a concept in place of class)?
// Volt's generics can't say it, so a call is checked by clang where it's made
fn is_static_cursor(c: clang::CXCursor) -> bool {
    return clang::clang_CXXMethod_isStatic(c) != 0;
}

fn constrained(c: clang::CXCursor) -> bool {
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (clang::clang_isExpression(k) != 0) {
            return true;
        }
        if (k == clang::CXCursor_TemplateTypeParameter) {
            for (d&) in children(*ch).items() {
                // template <std::integral T>: a reference to a concept
                if (clang::clang_getCursorKind(clang::clang_getCursorReferenced(*d)) == clang::CXCursor_ConceptDecl) {
                    return true;
                }
            }
        }
    }
    return false;
}

// a fn (head: its Volt signature up to the parameters) whose C++ (call: up to its arguments) Volt
// can't declare ahead: @cpp_call, so each call is worked out by clang where it's made (cpp_dyn_call).
// method: call is "obj.f(", and what's called is ".f"
attach fn per_use(this: cpp_gen&, head: str, call: str, method: bool) -> void {
    var callee = S(call);
    if (ends_with(callee.as_str(), "(")) {
        callee = S(callee.as_str()[0..callee.len() - 1]);
    }
    // explicit template arguments come from the Volt call (or C++ deduces them)
    val cs = callee.as_str();
    // (not operator>, >>, -> or <=>, whose names end in one)
    if (ends_with(cs, ">") && !ends_with(cs, "operator>") && !ends_with(cs, "operator>>") && !ends_with(cs, "operator->") && !ends_with(cs, "operator<=>")) {
        var depth: i32 = 0;
        var at = cs.len;
        while (at > 0) {
            at -= 1;
            if (cs[at] == '>') {
                depth += 1;
            } else if (cs[at] == '<') {
                depth -= 1;
                if (depth == 0) {
                    break;
                }
            }
        }
        if (depth == 0 && at > 0) {
            callee = S(cs[0..at]);
        }
    }
    if (method) {
        val ms = callee.as_str();
        var dot = ms.len;
        while (dot > 0 && ms[dot - 1] != '.') {
            dot -= 1;
        }
        if (dot > 0) {
            callee = S(ms[dot - 1..ms.len]);
        }
    }
    if (!this.first_time(head, "#per-use")) {
        return;
    }
    this.put_note();
    if (method && this.class_gen.len() > 0) {
        this.line(this.class_gen.as_str());
    }
    this.line(fmt("@attributes([@cpp_call(\"{}\")])", move callee).as_str());
    this.line(fmt("{}) -> void {{}}", S(head)).as_str());
}

// is this c's first declaration the import sees (by USR)? it's noted as seen
attach fn first_decl(this: cpp_gen&, c: clang::CXCursor) -> bool {
    val usr = cx_str(clang::clang_getCursorUSR(c));
    if (usr.len() == 0) {
        return true;
    }
    if (this.fns_seen.get(usr.as_str()) != null) {
        return false;
    }
    this.fns_seen.put(this.c.intern(move usr), true);
    return true;
}

// the public types inside class c, beside it (their Volt names are Outer_Inner: see scan)
attach fn nested(this: cpp_gen&, c: clang::CXCursor) -> void {
    for (ch&) in children(c).items() {
        if (this.skip(*ch)) {
            continue;
        }
        val acc = clang::clang_getCXXAccessSpecifier(*ch);
        if (acc == clang::CX_CXXPrivate || acc == clang::CX_CXXProtected) {
            continue;
        }
        val k = clang::clang_getCursorKind(*ch);
        if ((k == clang::CXCursor_ClassDecl || k == clang::CXCursor_StructDecl) && clang::clang_isCursorDefinition(*ch) != 0 && cursor_name(*ch).len() > 0) {
            this.class(*ch, null);
            this.nested(*ch);
        } else if (k == clang::CXCursor_EnumDecl) {
            this.enum_decl(*ch);
        }
    }
}

// a type's Volt name where it's declared: the last part of its path (Counter_Step for
// kit::Counter_Step), or its own name
fn last_part(path: str?, own: str) -> std::string {
    val p = path ?? return vname(own);
    var at: usize = 0;
    var i: usize = 0;
    while (i + 1 < p.len) {
        if (p[i] == ':' && p[i + 1] == ':') {
            at = i + 2;
        }
        i += 1;
    }
    return S(p[at..p.len]);
}

// a namespace constant (const or constexpr) of a number, bool, enum or text: a val of its value
attach fn constant(this: cpp_gen&, v: clang::CXCursor) -> void {
    val none: std::vec<str> = {};
    val t = clang::clang_getCursorType(v);
    if (clang::clang_isConstQualifiedType(t) == 0) {
        return; // a variable C++ may change
    }
    val ev = clang::clang_Cursor_Evaluate(v);
    if (ev == null) {
        return;
    }
    val ct = clang::clang_getCanonicalType(t);
    val kind = clang::clang_EvalResult_getKind(ev);
    var vty: std::string = {};
    var text: std::string = {};
    if (kind == clang::CXEval_Int && ct.kind == clang::CXType_Bool) {
        vty = S("bool");
        text = S("false");
        if (clang::clang_EvalResult_getAsLongLong(ev) != 0) {
            text = S("true");
        }
    } else if (kind == clang::CXEval_Int && ct.kind == clang::CXType_Enum) {
        // the enumerator with that value
        val n = clang::clang_EvalResult_getAsLongLong(ev);
        val e = clang::clang_getTypeDeclaration(ct);
        val ep = this.enums.get(cpp_qual(e).as_str());
        if (ep) {
            for (k&) in children(e).items() {
                if (clang::clang_getCursorKind(*k) == clang::CXCursor_EnumConstantDecl && clang::clang_getEnumConstantDeclValue(*k) == n) {
                    vty = S(*ep);
                    text = fmt2("{}::{}", S(*ep), vname(cursor_name(*k).as_str()));
                    break;
                }
            }
        }
    } else if (kind == clang::CXEval_Int) {
        vty = this.vtype(t, &none) ?? S("");
        if (clang::clang_EvalResult_isUnsignedInt(ev) != 0) {
            text = unum(clang::clang_EvalResult_getAsUnsigned(ev));
        } else {
            text = num(@cast<i128>(clang::clang_EvalResult_getAsLongLong(ev)));
        }
    } else if (kind == clang::CXEval_Float) {
        vty = this.vtype(t, &none) ?? S("");
        text = std::format("{}", clang::clang_EvalResult_getAsDouble(ev));
        // a Volt literal: digits, a point, signs and an exponent (not inf or nan)
        for (ch) in text.as_str() {
            if (!((ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '+' || ch == 'e')) {
                vty = S("");
            }
        }
    } else if (kind == clang::CXEval_StrLiteral) {
        vty = S("str");
        text = S("\"");
        val c = clang::clang_EvalResult_getAsStr(ev);
        var chars: str = "";
        if (c) {
            chars = @cast<str>(@slice(@cast<u8*>(c), strlen(c)));
        }
        for (ch) in chars {
            if (ch == '"' || ch == '\\') {
                text.push('\\');
                text.push(ch);
            } else if (ch == '\n') {
                text.append("\\n");
            } else if (ch == '\t') {
                text.append("\\t");
            } else if (ch < 32) {
                vty = S("");
            } else {
                text.push(ch);
            }
        }
        text.push('"');
    }
    clang::clang_EvalResult_dispose(ev);
    if (vty.len() > 0) {
        this.line(fmt3("val {}: {} = {};", vname(cursor_name(v).as_str()), move vty, move text).as_str());
    }
}

// the declarations the generated code relies on: stdcxx's smart pointers, and what a try_ form
// returns
attach fn std_extras(this: cpp_gen&) -> void {
    val fns = this.fn_sigs.len > 0;
    if (this.unique || this.shared || fns) {
        this.line("// the standard library types the headers' signatures use");
        this.line("namespace stdcxx {");
        this.depth += 1;
    }
    if (this.unique) {
        this.line("// std::unique_ptr<T>: owns the T a C++ function made; deleting it deletes the T");
        this.line("<T: type>");
        this.line("@attributes([@cpp_type(\"std::unique_ptr\")])");
        this.line("struct unique_ptr {");
        this.line("    _volt_p: T*;");
        this.line("}");
        this.line("<T: type>");
        this.line("attach fn delete(this: unique_ptr<T>&) -> void {");
        this.line("    @cpp<void, T>(\"{0}.~unique_ptr()\", this);");
        this.line("}");
        this.line("// the T it owns (null when it owns none)");
        this.line("<T: type>");
        this.line("attach fn get(this: unique_ptr<T>&) -> T* {");
        this.line("    return @cpp<T*, T>(\"{0}.get()\", this);");
        this.line("}");
    }
    if (this.shared) {
        this.line("// std::shared_ptr<T>: one of the owners of a T; copying adds an owner");
        this.line("<T: type>");
        this.line("@attributes([@cpp_type(\"std::shared_ptr\")])");
        this.line("struct shared_ptr {");
        this.line("    _volt_p: T*;");
        this.line("    _volt_count: void*;");
        this.line("}");
        this.line("<T: type>");
        this.line("attach fn delete(this: shared_ptr<T>&) -> void {");
        this.line("    @cpp<void, T>(\"{0}.~shared_ptr()\", this);");
        this.line("}");
        this.line("<T: type>");
        this.line("attach fn copy(this: shared_ptr<T>&) -> shared_ptr<T> {");
        this.line("    return @cpp<shared_ptr<T>, T>(\"std::shared_ptr<{t0}>({0})\", this);");
        this.line("}");
        this.line("<T: type>");
        this.line("attach fn get(this: shared_ptr<T>&) -> T* {");
        this.line("    return @cpp<T*, T>(\"{0}.get()\", this);");
        this.line("}");
        this.line("// how many owners the T has");
        this.line("<T: type>");
        this.line("attach fn use_count(this: shared_ptr<T>&) -> i64 {");
        this.line("    return @cpp<i64, T>(\"(long long){0}.use_count()\", this);");
        this.line("}");
    }
    if (fns) {
        this.fn_type();
    }
    if (this.unique || this.shared || fns) {
        this.depth -= 1;
        this.line("}");
    }
    if (this.tries) {
        this.exceptions();
        this.line("// what the exception a try_ form caught last (on this thread) said");
        this.line("fn last_exception() -> std::string {");
        this.depth += 1;
        this.line("val r = @cpp<str>(\"volt_cpp_dup(volt_cpp_last)\");");
        this.text_out("r");
        this.depth -= 1;
        this.line("}");
    }
}

// how many classes deep c is (a class with no bases is 1)
fn class_depth(c: clang::CXCursor, depth: u32) -> u32 {
    var most: u32 = 0;
    if (depth > 16) {
        return 1;
    }
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_CXXBaseSpecifier) {
            val b = clang::clang_getCursorDefinition(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(clang::clang_getCursorType(*ch))));
            if (clang::clang_Cursor_isNull(b) == 0) {
                val d = class_depth(b, depth + 1);
                if (d > most) {
                    most = d;
                }
            }
        }
    }
    return most + 1;
}

// what a try_ form's error says: cpp_error, a variant a standard exception and one each class of the
// headers deriving from std::exception; the C++ function telling which one was thrown (this.kinds,
// in the C++ unit once a try_ form names it); and the Volt fn turning its number into the variant
attach fn exceptions(this: cpp_gen&) -> void {
    val std_names: str[11] = { "out_of_range", "invalid_argument", "length_error", "domain_error", "logic_error", "range_error", "overflow_error", "underflow_error", "runtime_error", "bad_alloc", "bad_cast" };
    val variants: str[11] = { "OUT_OF_RANGE", "INVALID_ARGUMENT", "LENGTH_ERROR", "DOMAIN_ERROR", "LOGIC_ERROR", "RANGE_ERROR", "OVERFLOW_ERROR", "UNDERFLOW_ERROR", "RUNTIME_ERROR", "BAD_ALLOC", "BAD_CAST" };
    // the headers' own, most derived first (a catch takes the first that matches)
    var own: std::vec<str> = {};
    var depths: std::vec<u32> = {};
    var taken: std::map<str, bool> = {};
    for (i) in 0..11 {
        taken.put(variants[i], true);
    }
    taken.put("EXCEPTION", true);
    taken.put("UNKNOWN", true);
    for (e) in this.traits.iter() {
        if (!e.value.exception) {
            continue;
        }
        val c = *(this.cursors.get(*e.key) ?? continue);
        val name = this.c.intern(vname(cursor_name(c).as_str()));
        if (taken.get(name) != null) {
            this.line(fmt2("// ({} has no cpp_error variant of its own: {} is taken; its base's is the one)", S(*e.key), S(name)).as_str());
            continue;
        }
        taken.put(name, true);
        val d = class_depth(c, 0);
        var at = own.len;
        while (at > 0 && *depths.at(at - 1) < d) {
            at -= 1;
        }
        own.insert(at, *e.key) catch @panic("out of memory");
        depths.insert(at, d) catch @panic("out of memory");
    }
    this.line("// what a try_ form returns when the C++ code threw: a variant a standard exception, one each");
    this.line("// class of these headers deriving from std::exception, EXCEPTION for any other std::exception");
    this.line("// and UNKNOWN for what isn't one (last_exception() says what it said)");
    this.line("error cpp_error {");
    for (i) in 0..11 {
        this.line(fmt("    {},", S(variants[i])).as_str());
    }
    this.line("    EXCEPTION,");
    this.line("    UNKNOWN,");
    for (q&) in own.items() {
        this.line(fmt("    {},", vname(cursor_name(*(this.cursors.get(*q) ?? continue)).as_str())).as_str());
    }
    this.line("}");
    this.line("fn volt_cpp_error_of(k: i32) -> cpp_error {");
    for (i) in 0..11 {
        this.line(fmt2("    if (k == {}) {{ return cpp_error::{}; }}", unum(@cast<u64>(i + 1)), S(variants[i])).as_str());
    }
    this.line("    if (k == 12) { return cpp_error::EXCEPTION; }");
    for (i) in 0..own.len {
        this.line(fmt2("    if (k == {}) {{ return cpp_error::{}; }}", unum(@cast<u64>(i + 14)), vname(cursor_name(*(this.cursors.get(*own.at(i)) ?? continue)).as_str())).as_str());
    }
    this.line("    return cpp_error::UNKNOWN;");
    this.line("}");
    // the C++ side: rethrow what's being handled, and catch it most derived first
    var text = fmt("// which exception is being handled, as cpp_error numbers its variants (a try_ form's error)\nstatic int {}() {{\n    try {{\n        throw;\n", copy this.kinds);
    for (i) in 0..own.len {
        text.append(fmt2("    }} catch (const ::{} &e) {{\n        volt_cpp_last = e.what();\n        return {};\n", S(*own.at(i)), unum(@cast<u64>(i + 14))).as_str());
    }
    for (i) in 0..11 {
        text.append(fmt2("    }} catch (const std::{} &e) {{\n        volt_cpp_last = e.what();\n        return {};\n", S(std_names[i]), unum(@cast<u64>(i + 1))).as_str());
    }
    text.append("    } catch (const std::exception &e) {\n        volt_cpp_last = e.what();\n        return 12;\n    } catch (...) {\n        volt_cpp_last = \"an exception that isn't a std::exception\";\n        return 13;\n    }\n}\n");
    put(&this.c.cpp_decl_names, copy this.kinds);
    put(&this.c.cpp_decls, move text);
}

// ---------- the import ----------

// the directory a source file's local headers are looked for in (none for std's and generated files)
attach fn header_dir(this: checker&, span: span) -> str? {
    val file = this.files.at(@cast<usize>(span.file)).name;
    if (file.len > 0 && file[0] == '<') {
        return null;
    }
    var slash: usize? = null;
    for (i) in 0..file.len {
        if (file[i] == '/') {
            slash = i;
        }
    }
    val at = slash ?? return ".";
    if (at == 0) {
        return "/";
    }
    return file[0..at];
}

// the newest C++ standard both libclang and the C++ compiler take (found once a process): an
// import's, unless its @standard or the program's --cc -std=... says otherwise
var cpp_newest_found: str = "";

attach fn cpp_newest(this: checker&) -> str {
    if (this.opts.cpp_std.len > 0) {
        return this.opts.cpp_std; // --cc -std=c++17
    }
    if (cpp_newest_found.len == 0) {
        cpp_newest_found = "c++98";
        val all: str[6] = { "c++26", "c++23", "c++20", "c++17", "c++14", "c++11" };
        for (s) in all {
            var flag = S("-std=");
            flag.append(s);
            var args: std::vec<str> = {};
            put(&args, "-x");
            put(&args, "c++");
            put(&args, flag.as_str());
            val tu = clang_parse("volt_cpp_std.cpp", "", &args);
            if (tu.tu == null || tu.first_error() != null) {
                continue;
            }
            var argv: std::vec<str> = {};
            cxx_command(&argv);
            val rest: str[5] = { flag.as_str(), "-x", "c++", "-fsyntax-only", "-" };
            for (a) in rest {
                put(&argv, a);
            }
            val r = std::process::capture(argv.items(), "") catch |e| {
                cpp_newest_found = s; // no C++ compiler (an editor): libclang's says
                break;
            };
            if (r.code == 0) {
                cpp_newest_found = s;
                break;
            }
        }
    }
    return cpp_newest_found;
}

// the C++ unit for standard s (one per standard the program's imports use)
attach fn cpp_unit_for(this: checker&, s: str) -> u32 {
    for (i) in 0..this.cpp_units.len {
        if (*this.cpp_units.at(i) == s) {
            return @cast<u32>(i);
        }
    }
    put(&this.cpp_units, s);
    return @cast<u32>(this.cpp_units.len - 1);
}

// libclang's arguments for C++ under standard s
attach fn cpp_args(this: checker&, s: str) -> std::vec<str> {
    var args: std::vec<str> = {};
    put(&args, "-x");
    put(&args, "c++");
    put(&args, this.intern(fmt("-std={}", S(s))));
    for (f&) in this.opts.pp_flags.items() {
        put(&args, *f);
    }
    return args;
}

attach fn import_cpp(this: checker&, headers: std::vec<std::string>&, alias: str, ns: u32, standard: str, span: span) -> compile_error!void {
    var std_name = standard;
    if (std_name.len == 0) {
        std_name = this.cpp_newest();
    }
    val unit = this.cpp_unit_for(std_name);
    // the #include lines: a header next to the source file by its full path, others from the system
    var src: std::string = {};
    val dir = this.header_dir(span);
    for (h&) in headers.items() {
        var local: std::string? = null;
        if (dir) {
            var p = S(dir);
            p.push('/');
            p.append(h.as_str());
            local = real_file(p.as_str());
        }
        var line: std::string = {};
        if (local) {
            line = fmt("#include \"{}\"", copy local);
        } else {
            line = fmt("#include <{}>", copy *h);
        }
        src.append(line.as_str());
        src.push('\n');
        var have = false;
        for (i) in 0..this.cpp_includes.len {
            if (*this.cpp_includes.at(i) == line.as_str() && *this.cpp_include_unit.at(i) == unit) {
                have = true;
            }
        }
        if (!have) {
            put(&this.cpp_includes, this.intern(move line));
            put(&this.cpp_include_unit, unit);
        }
    }
    val args = this.cpp_args(std_name);
    // CXTranslationUnit_SkipFunctionBodies | DetailedPreprocessingRecord (the macros)
    var tu = clang_parse_opts("volt_cpp_import.cpp", src.as_str(), &args, 65);
    val bad = tu.first_error();
    if (bad) {
        return fail(span, fmt("libclang couldn't read these C++ headers: {}", copy bad));
    }
    var g: cpp_gen = { c: this, kinds: fmt("volt_cpp_kinds_{}", unum(@cast<u64>(this.cpp_items.len))) };
    g.library_roots(headers, &tu);
    g.scan(tu.root(), "");
    g.probe(src.as_str(), &args);
    g.prune();
    g.out.append(fmt("// the Volt side of use cpp {{ ... }} as {} (generated by voltc from the headers)\n", S(alias)).as_str());
    g.emit(tu.root());
    g.std_extras();
    val n = this.ns_child(ns, alias);
    // kept for the calls made per use (cpp_dyn_call)
    // it's Volt source like any other: lexed, parsed and declared in namespace `alias`
    var fname = S("<use cpp as ");
    fname.append(alias);
    fname.push('>');
    // VOLT_SHOW_CPP=1 prints it: what the headers became
    if (std::process::env("VOLT_SHOW_CPP") != null) {
        std::eprint("{}", g.out);
    }
    put(&this.c_texts, copy g.out);
    g.out = {};
    // kept for the calls made per use (cpp_dyn_call)
    put(&this.cpp_ctxs, { ns: n, src: copy src, args: copy args, gen: move g, tu: move tu, unit: unit });
    val text = this.c_texts.at(this.c_texts.len - 1).as_str();
    put(this.files, { name: this.intern(move fname), text: text });
    val file = @cast<u32>(this.files.len - 1);
    val toks = try lex(text, file);
    var names: std::map<str, bool> = {};
    collect_generic_names(&toks, &names);
    var p: parser = { src: text, toks: &toks, pos: 0, generics: &names };
    val items = try p.parse_file();
    put(&this.cpp_items, bx(move items));
    return this.collect(*this.cpp_items.at(this.cpp_items.len - 1), n);
}

// ---------- calls made per use ----------

// A C++ import kept for the calls Volt can't declare ahead (a variadic or non-type template, an auto
// result, a constrained template, a function-like macro: @cpp_call names them): its namespace, the
// headers and clang's arguments, what its scan learned (cpp_gen's maps, whose cursors point into
// tu), and the unit each call is worked out in (its preamble the headers, parsed once)
struct cpp_import_ctx {
    ns: u32;
    src: std::string;
    args: std::vec<str>;
    gen: cpp_gen;
    tu: clang_tu;
    probe: clang_tu = { index: null, tu: null };
    unit: u32 = 0; // its C++ unit (cpp_units: the standard it's compiled under)
}

// what a call per use declares in C++ besides the headers: the types an argument may come as, and
// stand-ins for the arguments (an lvalue, or an rvalue for a class moved in) in any standard
val CPP_PROBE_HEAD: str = "\n#include <cstddef>\n#include <functional>\n#include <string>\n#include <utility>\n#include <vector>\n#if __cplusplus >= 201103L\n#include <cstdint>\n#endif\n#if __cplusplus >= 201703L\n#include <string_view>\n#endif\ntemplate <class T> T &volt_lv();\ntemplate <class T> T volt_rv();\n";

// the import namespace ns is in (or under), by its context's index
attach fn cpp_ctx_of(this: checker&, ns: u32) -> usize? {
    var at: u32? = ns;
    while (at) {
        val n = at;
        for (k) in 0..this.cpp_ctxs.len {
            if (this.cpp_ctxs.at(k).ns == n) {
                return k;
            }
        }
        at = this.ns(n).parent;
    }
    return null;
}

// the C++ an @cpp_call declaration names ("ns::f", or ".f" for a method), if d is one
attach fn cpp_call_attr(this: checker&, d: u32) -> str? {
    for (a&) in this.item_of(d).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {
                if (n == "cpp_call") {
                    return attr_str(a);
                }
            },
            default => {},
        }
    }
    return null;
}

// the C++ type a value of Volt type t is handed to C++ as, in a call made per use: the one the
// importer maps back to t (a str as a const std::string &, a reference as a C++ reference, a class
// by value, a fn value as a std::function)
attach fn cpp_probe_type(this: checker&, t: u32) -> std::string? {
    match (*this.t.get(t)) {
        .STR => { return S("const std::string &"); },
        .REF(x) => {
            var s = this.cpp_probe_type(x) ?? return null;
            if (ends_with(s.as_str(), "&")) {
                return s;
            }
            s.append(" &");
            return s;
        },
        .SLICE(x) => {
            val e = this.cpp_probe_type(x) ?? return null;
            return fmt("const std::vector<{}> &", move e);
        },
        default => { return this.cpp_spell(t); },
    }
}

// a C++ expression with holes ({0}, {1}...) for these Volt types, as a Volt fn made for them: clang
// works out the expression's type with each hole a parameter of the C++ type the argument comes as
// (an error is its words, at span), and the importer writes the fn as it would for a C++ function of
// that signature. recv: {0} is the receiver, so it's an attach fn on it. The fn's declaration
attach fn cpp_instance(this: checker&, k: usize, expr: str, types: std::vec<u32>&, recv: bool, value: bool, span: span) -> compile_error!u32 {
    var ptys: std::vec<std::string> = {};
    // a reference result can only be into the receiver, a reference argument or something that
    // outlives the call: with none of the first two, it's into the wrapper's own copies, so the
    // value comes back
    var by_value = value || !recv;
    for (t&) in types.items() {
        put(&ptys, this.cpp_probe_type(*t) ?? return fail(span, fmt("C++ can't be handed {}", this.ty_name(*t))));
        match (*this.t.get(*t)) {
            .REF(x) => { by_value = value; },
            default => {},
        }
    }
    var key = fmt2("{}|{}|", unum(@cast<u64>(k)), S(expr));
    if (by_value) {
        key.append("value|");
    }
    for (p&) in ptys.items() {
        key.append(p.as_str());
        key.push(',');
    }
    val have = this.cpp_dyn.get(key.as_str());
    if (have) {
        return *have;
    }
    val n = @cast<u64>(this.cpp_dyn_n);
    this.cpp_dyn_n += 1;
    // the probe: a function of the arguments' types whose result is the expression's
    var params: std::string = {};
    for (i) in 0..ptys.len {
        if (i > 0) {
            params.append(", ");
        }
        params.append(fmt2("{} a{}", copy *ptys.at(i), unum(@cast<u64>(i))).as_str());
    }
    var probe_expr: std::string = {};
    var i: usize = 0;
    while (i < expr.len) {
        if (expr[i] == '{') {
            var e = i + 1;
            while (e < expr.len && expr[e] != '}') {
                e += 1;
            }
            val h = hole_index(expr[i + 1..e]);
            if (h != null && (h ?? 0) < ptys.len) {
                // a class by value is moved into the call, as the wrapper does
                val hi = h ?? 0;
                if (this.cpp_is_class(*types.at(hi))) {
                    probe_expr.append(fmt("volt_rv<{} >()", copy *ptys.at(hi)).as_str());
                } else {
                    probe_expr.append(fmt("volt_lv<{} >()", copy *ptys.at(hi)).as_str());
                }
                i = e + 1;
                continue;
            }
        }
        probe_expr.push(expr[i]);
        i += 1;
    }
    val pname = fmt("volt_probe_{}", unum(n));
    var text = copy this.cpp_ctxs.at(k).src;
    text.append(CPP_PROBE_HEAD);
    // clang's __decltype and __decay, which it has in every standard (the probe is only libclang's)
    if (by_value) {
        // a macro's or an expression's lvalue is the wrapper's own parameter: its value comes back
        probe_expr = fmt("__decay(__decltype({}))", move probe_expr);
    } else {
        probe_expr = fmt("__decltype({})", move probe_expr);
    }
    text.append(fmt3("{} {}({});\n", move probe_expr, copy pname, move params).as_str());
    val main = "volt_cpp_call.cpp";
    val x = this.cpp_ctxs.at(k);
    if (x.probe.tu == null || !x.probe.reparse(main, text.as_str())) {
        // CXTranslationUnit_PrecompiledPreamble | CreatePreambleOnFirstParse: the headers once
        x.probe = clang_parse_opts(main, text.as_str(), &x.args, 260);
    }
    val tu = &x.probe;
    val errs = tu.errors_text(main);
    if (errs) {
        return fail(span, fmt("C++ can't make this call:\n{}", copy errs));
    }
    var found: clang::CXCursor? = null;
    for (c&) in children(tu.root()).items() {
        if (clang::clang_getCursorKind(*c) == clang::CXCursor_FunctionDecl && cursor_name(*c).as_str() == pname.as_str()) {
            found = *c;
        }
    }
    val fc = found ?? return fails(span, "libclang lost the call");
    // the Volt fn, written by the importer from the probe's now concrete signature
    val g = &this.cpp_ctxs.at(k).gen;
    val none: std::vec<str> = {};
    val fname = fmt("volt_cpp_call_{}", unum(n));
    // the type itself, not decltype(...) of the probe
    val rt = clang::clang_getCanonicalType(clang::clang_getCursorResultType(fc));
    val r = g.result(rt, &none);
    var why: std::string? = null;
    if (r == null) {
        why = fmt("its result, {}, has no Volt form yet", type_spelling(rt));
    }
    var sig = S("fn ");
    if (recv) {
        sig = S("attach fn ");
    }
    sig.append(fname.as_str());
    sig.push('(');
    var body = S("");
    var tail = S("");
    val parms = params_of(fc);
    var args: std::vec<cpp_arg> = {};
    for (j) in 0..parms.len {
        var an = fmt("a{}", unum(@cast<u64>(j)));
        if (recv && j == 0) {
            an = S("this");
        }
        val pt = clang::clang_getCursorType(*parms.at(j));
        val a = g.param(pt, an.as_str(), j, &none);
        if (a == null && why == null) {
            why = fmt("{} has no Volt form yet", type_spelling(pt));
        }
        if (a) {
            if (j > 0) {
                sig.append(", ");
            }
            sig.append(fmt2("{}: {}", copy an, copy a.vty).as_str());
            tail.append(", ");
            tail.append(a.pass.as_str());
            put(&args, copy a);
        }
    }
    if (why) {
        return fail(span, fmt("Volt can't take this C++ call yet: {}", copy why));
    }
    var rr: cpp_ret = { vty: S("void") };
    if (r) {
        rr = copy r;
    }
    sig.append(fmt(") -> {}", copy rr.vty).as_str());
    // the expression again, each hole the importer's conversion of its argument
    i = 0;
    while (i < expr.len) {
        if (expr[i] == '{') {
            var e = i + 1;
            while (e < expr.len && expr[e] != '}') {
                e += 1;
            }
            val h = hole_index(expr[i + 1..e]);
            if (h != null && (h ?? 0) < args.len) {
                body.append(args.at(h ?? 0).cpp.as_str());
                i = e + 1;
                continue;
            }
        }
        body.push(expr[i]);
        i += 1;
    }
    // the call clang worked out, with its argument and result types
    var inst = S(expr);
    for (j) in 0..ptys.len {
        inst = replace_all(inst.as_str(), fmt("{{{}}}", unum(@cast<u64>(j))).as_str(), ptys.at(j).as_str());
    }
    g.note = fmt2("{} -> {}, as clang resolves it", move inst, type_spelling(rt));
    g.fn_text("", sig.as_str(), &rr, body.as_str(), tail.as_str(), "");
    var out = copy g.out;
    g.out = {};
    // declared in the import's namespace, as the import's own fns are
    put(&this.c_texts, move out);
    val src = this.c_texts.at(this.c_texts.len - 1).as_str();
    var fl = S("<C++ call ");
    fl.append(expr);
    fl.push('>');
    put(this.files, { name: this.intern(move fl), text: src });
    val file = @cast<u32>(this.files.len - 1);
    val toks = try lex(src, file);
    var names: std::map<str, bool> = {};
    collect_generic_names(&toks, &names);
    var p: parser = { src: src, toks: &toks, pos: 0, generics: &names };
    val items = try p.parse_file();
    put(&this.cpp_items, bx(move items));
    val first = this.decls.len;
    val at = this.cpp_items.len - 1;
    val home = this.cpp_ctxs.at(k).ns;
    for (j) in 0..(*this.cpp_items.at(at)).len {
        try this.collect_item((*this.cpp_items.at(at)).at(j), home, null);
    }
    var d: u32? = null;
    for (j) in first..this.decls.len {
        val fd = this.fn_decl_of(@cast<u32>(j));
        if (fd != null && d == null) {
            d = @cast<u32>(j);
        }
    }
    val made = d ?? return fails(span, "the C++ call's Volt fn wasn't declared");
    this.cpp_dyn.put(this.intern(move key), made);
    return made;
}

// a call of an @cpp_call declaration (d): the C++ it names, with these arguments and explicit
// template arguments, made per use (cpp_instance) and called like any fn
attach fn cpp_dyn_call(this: checker&, d: u32, name: str, rv: tval?, explicit: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    var callee = this.cpp_call_attr(d) ?? "";
    // "#NAME" is a function-like macro: what it expands to comes back by value
    val macro = starts_with(callee, "#");
    if (macro) {
        callee = callee[1..callee.len];
    }
    val k = this.cpp_ctx_of(this.decls.at(@cast<usize>(d)).ns) ?? return fails(span, "this C++ name's import is gone");
    var targs = S("");
    if (explicit.len > 0) {
        targs.push('<');
        for (j) in 0..explicit.len {
            if (j > 0) {
                targs.append(", ");
            }
            match (*explicit.at(j)) {
                .TYPE(t&) => {
                    val ty = try this.garg_type(explicit.at(j));
                    targs.append((this.cpp_spell(ty) ?? return fail(t.span, fmt("{} has no C++ spelling", this.ty_name(ty)))).as_str());
                },
                .EXPR(e&) => {
                    match (try this.ct_eval(e, null)) {
                        .INT(v, t) => { targs.append(num(v).as_str()); },
                        .BOOL(b) => {
                            if (b) {
                                targs.append("true");
                            } else {
                                targs.append("false");
                            }
                        },
                        .TYPE(ty) => { targs.append((this.cpp_spell(ty) ?? return fail(e.span, fmt("{} has no C++ spelling", this.ty_name(ty)))).as_str()); },
                        default => { return fails(e.span, "a C++ template argument is a type, an integer or a bool"); },
                    }
                },
            }
        }
        targs.push('>');
    }
    var types: std::vec<u32> = {};
    var pre: std::vec<tval?> = {};
    var expr = S("");
    var holes: usize = 0;
    var rp: tval* = null;
    var rcopy = rv ?? vnew(0, 0);
    if (rv) {
        // {0}.f(...): the receiver as a reference
        rp = &rcopy;
        var rt = rcopy.ty;
        match (*this.t.get(rt)) {
            .REF(x) => { rt = x; },
            default => {},
        }
        put(&types, this.t.intern(tyk::REF(rt)));
        expr = fmt2("{{0}}{}{}(", S(callee), copy targs);
        holes = 1;
    } else {
        expr = fmt2("{}{}(", S(callee), copy targs);
    }
    for (j) in 0..args.len {
        val a = args.at(j);
        if (needs_context(a)) {
            return fails(a.span, "C++ works this call out from its arguments' types: give this one a type (a typed val)");
        }
        val v = try this.expr(a, null);
        put(&types, v.ty);
        put(&pre, v);
        if (j > 0) {
            expr.append(", ");
        }
        expr.append(fmt("{{{}}}", unum(@cast<u64>(holes + j))).as_str());
    }
    expr.push(')');
    val made = try this.cpp_instance(k, expr.as_str(), &types, rv != null, macro, span);
    var cands: std::vec<u32> = {};
    put(&cands, made);
    var none: std::vec<garg> = {};
    val r = try this.pick_call(name, &cands, rp, null, &none, &pre, args, want, span);
    if (this.opts.lsp) {
        // hover on the name shows the instance (and, above it, the call clang worked out)
        this.lsp_fn_use_as(made, null, span, name);
    }
    return r;
}

// @cpp("C++ expression", args...) with no result type: clang works it out, as for a call made per
// use, in the first C++ import's headers (or none)
attach fn cpp_typed_by_clang(this: checker&, args: std::vec<garg>&, span: span) -> compile_error!tval {
    val fe = try this.garg_value(args.at(0));
    var text: std::string = {};
    match (fe.kind) {
        .STR(s) => { text = copy s; },
        default => { return fails(span, "@cpp's first argument is the C++ expression, as a string literal"); },
    }
    if (contains(text.as_str(), "{&") || contains(text.as_str(), "{=") || contains(text.as_str(), "{t")) {
        return fails(span, "@cpp with {&i}, {=i} or {tN} holes says its result type: @cpp<R>(...)");
    }
    var types: std::vec<u32> = {};
    var pre: std::vec<tval?> = {};
    var es: std::vec<expr> = {};
    for (i) in 1..args.len {
        match (*args.at(i)) {
            .EXPR(e&) => {
                val v = try this.expr(e, null);
                put(&types, v.ty);
                put(&pre, v);
                put(&es, copy *e);
            },
            .TYPE(t&) => { return fails(t.span, "@cpp's arguments are values"); },
        }
    }
    if (this.cpp_ctxs.len == 0) {
        // no import: the C++ standard library's headers alone
        val newest = this.cpp_newest();
        var cargs = this.cpp_args(newest);
        var g: cpp_gen = { c: this, kinds: S("volt_cpp_kinds_none") };
        val tu = clang_parse("volt_cpp_none.cpp", "", &cargs);
        put(&this.cpp_ctxs, { ns: this.env_at(this.cx.env).ns, src: {}, args: move cargs, gen: move g, tu: move tu, unit: this.cpp_unit_for(newest) });
    }
    val made = try this.cpp_instance(0, text.as_str(), &types, false, true, span);
    var cands: std::vec<u32> = {};
    put(&cands, made);
    var none: std::vec<garg> = {};
    return this.pick_call("@cpp", &cands, null, null, &none, &pre, &es, null, span);
}

// ---------- @cpp: calling C++ ----------

// the C++ spelling of a Volt type in a wrapper's signature (a reference is a pointer, an enum its tag)
attach fn cpp_spell(this: checker&, t: u32) -> std::string? {
    match (*this.t.get(t)) {
        .VOID => { return S("void"); },
        .BOOL => { return S("bool"); },
        .INT(k) => { return S(int_c(k)); },
        .FLOAT(b) => {
            if (b == 32) {
                return S("float");
            }
            if (b == 64) {
                return S("double");
            }
            return null;
        },
        .CSTR => { return S("const char *"); },
        .STR => { return S("volt_str"); },
        .SLICE(x) => {
            val e = this.cpp_spell(x) ?? return null;
            return fmt("volt_slice<{}>", move e);
        },
        .VOIDPTR => { return S("void *"); },
        .OPT(x) => {
            if (this.t.is_niche(x)) {
                return this.cpp_spell(x);
            }
            return null;
        },
        .PTR(x) => {
            var s = this.cpp_spell(x) ?? return null;
            s.append(" *");
            return s;
        },
        .REF(x) => {
            var s = this.cpp_spell(x) ?? return null;
            s.append(" *");
            return s;
        },
        .ENUM(e) => {
            if (this.ei(e).has_payload) {
                return null;
            }
            return S(int_c(this.ei(e).tag));
        },
        .STRUCT(s) => { return this.cpp_class(s); },
        default => { return null; },
    }
}

// the C++ name of a struct imported from C++ (@cpp_type), with a template instance's arguments
attach fn cpp_class(this: checker&, s: u32) -> std::string? {
    val info = this.si(s);
    for (a&) in this.item_of(info.decl).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {
                if (n != "cpp_type") {
                    continue;
                }
                var out = S(attr_str(a) ?? return null);
                if (info.args.len > 0) {
                    out.push('<');
                    for (i) in 0..info.args.len {
                        if (i > 0) {
                            out.append(", ");
                        }
                        match (*info.args.at(i)) {
                            .TY(t) => {
                                val sp = this.cpp_spell(t) ?? return null;
                                out.append(sp.as_str());
                            },
                            .INT(v) => { out.append(num(v).as_str()); },
                            default => { return null; },
                        }
                    }
                    out.push('>');
                }
                return out;
            },
            default => {},
        }
    }
    return null;
}

attach fn cpp_is_class(this: checker&, t: u32) -> bool {
    match (*this.t.get(t)) {
        .STRUCT(s) => { return this.cpp_class(s) != null; },
        default => { return false; },
    }
}

// @cpp<R, T...>("C++ expression", args...): a call into C++ (cppimport.volt writes these). In the
// expression {i} is argument i (a reference arrives as the object it refers to) and {tN} the C++
// spelling of the Nth type after R; {&i} is argument i, a function, by its C symbol (declared
// extern "C" for the expression), and {=i} argument i, a comptime value, as a C++ literal: those two
// aren't passed. Each distinct call becomes an extern "C" wrapper function in the
// program's C++ file (cpp_unit): a C++ class comes back through a pointer to the result's place,
// a reference as a pointer, anything else by value
attach fn cpp_call(this: checker&, gargs: std::vec<garg>&, args: std::vec<garg>&, span: span) -> compile_error!tval {
    if (args.len == 0) {
        return fails(span, "@cpp<R>(\"C++ expression\", args...)");
    }
    if (gargs.len == 0) {
        return this.cpp_typed_by_clang(args, span);
    }
    val r = try this.garg_type(gargs.at(0));
    var types: std::vec<std::string> = {};
    for (i) in 1..gargs.len {
        val t = try this.garg_type(gargs.at(i));
        val sp = this.cpp_spell(t) ?? return fail(span, fmt("@cpp: {} has no C++ spelling", this.ty_name(t)));
        put(&types, move sp);
    }
    val fe = try this.garg_value(args.at(0));
    var text: std::string = {};
    match (fe.kind) {
        .STR(s) => { text = copy s; },
        default => { return fails(span, "@cpp's first argument is the C++ expression, as a string literal"); },
    }
    val class_ret = this.cpp_is_class(r);
    var rsp = S("void");
    if (!class_ret && r != VOID) {
        rsp = this.cpp_spell(r) ?? return fail(span, fmt("@cpp: it returns {}, which has no C++ form", this.ty_name(r)));
    }
    // which arguments are {&i} and {=i} holes
    var how: std::vec<u8> = {};
    for (i) in 1..args.len {
        put(&how, 0);
    }
    val tx0 = text.as_str();
    for (k) in 0..tx0.len {
        if (tx0[k] == '{' && k + 2 < tx0.len && (tx0[k + 1] == '&' || tx0[k + 1] == '=')) {
            var e = k + 2;
            while (e < tx0.len && tx0[e] != '}') {
                e += 1;
            }
            val n = hole_index(tx0[k + 2..e]) ?? return fail(span, fmt("@cpp: {{{}}} names no argument", S(tx0[k + 1..e])));
            if (n + 1 >= args.len) {
                return fail(span, fmt("@cpp: no argument for {{{}}} in the C++ expression", S(tx0[k + 1..e])));
            }
            *how.at(n) = tx0[k + 1];
        }
    }
    var params: std::string = {};
    var ptys: std::vec<u32> = {};
    var vals: std::vec<u32> = {};
    var subst: std::vec<std::string> = {};
    var decls: std::string = {};
    if (class_ret) {
        params.append((this.cpp_spell(r) ?? S("void")).as_str());
        params.append(" *ret");
        put(&ptys, this.t.intern(tyk::PTR(r)));
    }
    for (i) in 1..args.len {
        if (*how.at(i - 1) == '&') {
            val fv = try this.garg_expr(args.at(i), VOIDPTR);
            var sym = S("");
            match (this.ir.at(fv.c).kind) {
                .FN(f) => {
                    // C++ calls it by name: visible outside the program's own unit
                    sym = S(this.ir.fn_at(f).name);
                    if (this.ir.fn_at(f).link == linkage::STATIC) {
                        this.ir.fn_at(f).link = linkage::EXPORTED;
                    }
                },
                default => { return fail(span, fmt("@cpp: {{&{}}} is a function's symbol: pass a function", unum(@cast<u64>(i - 1)))); },
            }
            match (*this.t.get(fv.ty)) {
                .FN_PTR(ps&, ret, va) => {
                    var rs = S("void");
                    if (ret != VOID) {
                        rs = this.cpp_spell(ret) ?? return fail(span, fmt("@cpp: {} has no C++ form", this.ty_name(ret)));
                    }
                    var pl: std::string = {};
                    for (pt&) in ps.items() {
                        if (pl.len() > 0) {
                            pl.append(", ");
                        }
                        pl.append((this.cpp_spell(*pt) ?? return fail(span, fmt("@cpp: {} has no C++ form", this.ty_name(*pt)))).as_str());
                    }
                    if (pl.len() == 0) {
                        pl.append("void");
                    }
                    decls.append(fmt3("extern \"C\" {} {}({});\n", move rs, copy sym, move pl).as_str());
                },
                default => {},
            }
            put(&subst, move sym);
            continue;
        }
        if (*how.at(i - 1) == '=') {
            var lit = S("");
            match (*args.at(i)) {
                .EXPR(e&) => {
                    match (try this.ct_eval(e, null)) {
                        .BOOL(b) => {
                            lit = S("false");
                            if (b) {
                                lit = S("true");
                            }
                        },
                        .INT(v, t) => { lit = num(v); },
                        default => { return fail(e.span, fmt("@cpp: {{={}}} is a comptime bool or integer", unum(@cast<u64>(i - 1)))); },
                    }
                },
                .TYPE(t&) => { return fail(t.span, fmt("@cpp: {{={}}} is a comptime bool or integer", unum(@cast<u64>(i - 1)))); },
            }
            put(&subst, move lit);
            continue;
        }
        var v = try this.garg_expr(args.at(i), null);
        v = try this.take(v, span);
        if (this.cpp_is_class(v.ty)) {
            return fail(span, fmt("@cpp: pass the C++ object {} by reference (&x)", this.ty_name(v.ty)));
        }
        val sp = this.cpp_spell(v.ty) ?? return fail(span, fmt2("@cpp: argument {} is {}, which has no C++ form", unum(@cast<u64>(i - 1)), this.ty_name(v.ty)));
        if (params.len() > 0) {
            params.append(", ");
        }
        var an = S("a");
        an.append_uint(@cast<u64>(i - 1));
        params.append(fmt2("{} {}", move sp, copy an).as_str());
        match (*this.t.get(v.ty)) {
            .REF(x) => { put(&subst, fmt("(*{})", copy an)); },
            default => { put(&subst, copy an); },
        }
        put(&ptys, v.ty);
        put(&vals, v.c);
    }
    if (params.len() == 0) {
        params.append("void");
    }
    // the expression with its holes filled
    var expr: std::string = {};
    var k: usize = 0;
    val tx = text.as_str();
    while (k < tx.len) {
        if (tx[k] == '{') {
            var e = k + 1;
            while (e < tx.len && tx[e] != '}') {
                e += 1;
            }
            var hole = tx[k + 1..e];
            var done = false;
            if (hole.len > 0 && (hole[0] == '&' || hole[0] == '=')) {
                hole = hole[1..hole.len];
            }
            if (hole.len > 0 && hole[0] == 't') {
                val n = hole_index(hole[1..hole.len]);
                if (n != null && (n ?? 0) < types.len) {
                    expr.append(types.at(n ?? 0).as_str());
                    done = true;
                }
            } else {
                val n = hole_index(hole);
                if (n != null && (n ?? 0) < subst.len) {
                    expr.append(subst.at(n ?? 0).as_str());
                    done = true;
                }
            }
            if (!done) {
                return fail(span, fmt("@cpp: no argument for {{{}}} in the C++ expression", S(hole)));
            }
            k = e + 1;
            continue;
        }
        expr.push(tx[k]);
        k += 1;
    }
    var body: std::string = {};
    if (r == VOID) {
        body = fmt("{};", move expr);
    } else if (class_ret) {
        body = fmt2("new (ret) {}({});", this.cpp_spell(r) ?? S("void"), move expr);
    } else {
        match (*this.t.get(r)) {
            // the reference's address, as the wrapper's pointer type (Volt has no const: a const&
            // result is a reference like any other)
            .REF(x) => { body = fmt2("return ({})&({});", copy rsp, move expr); },
            default => { body = fmt2("return ({})({});", copy rsp, move expr); },
        }
    }
    // one wrapper per distinct call, in the C++ unit of the import it's from; the program's own in
    // the default standard's, or when no import is in that one, the first import's
    var unit: u32 = 0;
    val from = this.cpp_ctx_of(this.env_at(this.cx.env).ns);
    if (from) {
        unit = this.cpp_ctxs.at(from).unit;
    } else {
        unit = this.cpp_unit_for(this.cpp_newest());
        var any = false;
        for (x&) in this.cpp_ctxs.items() {
            any = any || x.unit == unit;
        }
        if (!any && this.cpp_ctxs.len > 0) {
            unit = this.cpp_ctxs.at(0).unit;
        }
    }
    var key = fmt3("{}({}){}", copy rsp, copy params, copy body);
    key.push('@');
    key.append_uint(@cast<u64>(unit));
    var idx: u32 = 0;
    val have = this.cpp_shim_keys.get(key.as_str());
    if (have) {
        idx = *have;
    } else {
        idx = @cast<u32>(this.cpp_shims.len);
        var name = S("volt_cpp_");
        name.append_uint(@cast<u64>(idx));
        var w = copy decls;
        w.append(fmt3("{} {}({}) {{\n", copy rsp, copy name, copy params).as_str());
        w.append(fmt("    try {{\n        {}\n    }} catch (const std::exception &e) {{\n        volt_cpp_throw(e.what());\n    }} catch (...) {{\n        volt_cpp_throw(\"an exception that isn't a std::exception\");\n    }}\n}}\n", copy body).as_str());
        put(&this.cpp_shims, move w);
        put(&this.cpp_shim_unit, unit);
        this.cpp_shim_keys.put(this.intern(copy key), idx);
        var ret_ty = r;
        if (class_ret) {
            ret_ty = VOID;
        }
        var irf: ir_fn = { name: this.intern(move name), params: {}, ret: ret_ty, link: linkage::EXTERNAL, used: true };
        for (i) in 0..ptys.len {
            put(&irf.locals, { name: "a", ty: *ptys.at(i) });
            put(&irf.params, @cast<u32>(i));
        }
        put(&this.ir.fns, bx(move irf));
        val f = @cast<u32>(this.ir.fns.len - 1);
        put(&this.ir.order, f);
        put(&this.cpp_shim_fns, f);
    }
    val f = *this.cpp_shim_fns.at(@cast<usize>(idx));
    if (class_ret) {
        // the object is made in place, in a local the call's value then is
        val tmp = this.tmp_local("cpp", r);
        var all: std::vec<u32> = {};
        put(&all, this.ir.node(ir_kind::ADDR(tmp.c), this.t.intern(tyk::PTR(r))));
        for (v&) in vals.items() {
            put(&all, *v);
        }
        return vnew(r, this.ir.seq(nodes2(this.ir.decl(tmp.id, null), this.call_fn(f, move all, VOID)), tmp.c, r));
    }
    if (r == VOID) {
        return this.vstmt(this.call_fn(f, move vals, VOID));
    }
    return vnew(r, this.call_fn(f, move vals, r));
}

fn hole_index(s: str) -> usize? {
    if (s.len == 0) {
        return null;
    }
    var n: usize = 0;
    for (c) in s {
        if (c < '0' || c > '9') {
            return null;
        }
        n = n * 10 + @cast<usize>(c - '0');
    }
    return n;
}

// the start of each C++ unit, before the headers: what it includes, and what its wrappers write
// differently by standard (valid C++98 through C++26, as is CPP_PRELUDE)
val CPP_UNIT_HEAD: str = "#include <algorithm>\n#include <cstddef>\n#include <cstdio>\n#include <cstdlib>\n#include <cstring>\n#include <exception>\n#include <functional>\n#include <memory>\n#include <new>\n#include <stdexcept>\n#include <stdint.h>\n#include <string>\n#include <typeinfo>\n#include <utility>\n#include <vector>\n#if __cplusplus >= 201103L\n#include <cstdint>\n#include <type_traits>\n#endif\n#if __cplusplus >= 201703L\n#include <string_view>\n#endif\n#if __has_include(<cxxabi.h>)\n#include <cxxabi.h>\n#endif\n\n// RTTI (dynamic_cast, typeid): only what needs it uses it, and a build without it (-fno-rtti) has the rest\n#if defined(__GXX_RTTI) || defined(__cpp_rtti) || defined(_CPPRTTI)\n#define VOLT_RTTI 1\n#else\n#define VOLT_RTTI 0\n#endif\n\n// what the wrappers write differently by standard: a move, a type spelled anywhere, an expression's\n// type without its reference (C++98 has no moves, decltype or alias templates)\ntemplate <class T>\nstruct volt_idt {\n    typedef T type;\n};\n\n#if __cplusplus >= 201103L\n#define VOLT_MOVE(...) std::move(__VA_ARGS__)\n#define VOLT_NOREF(...) std::remove_reference<decltype(__VA_ARGS__)>::type\n#define VOLT_NORETURN [[noreturn]]\n#define VOLT_TLS thread_local\n#else\n#define VOLT_MOVE(...) (__VA_ARGS__)\n#define VOLT_NOREF(...) __typeof__(__VA_ARGS__)\n#define VOLT_NORETURN __attribute__((noreturn))\n#define VOLT_TLS\n#endif\n#define VOLT_ID(...) volt_idt<__VA_ARGS__ >::type\n";

// after the headers: what the wrappers call
val CPP_PRELUDE: str = "\n// an exception that reaches Volt stops the program, like a panic\nVOLT_NORETURN static void volt_cpp_throw(const char *what) {\n    std::fprintf(stderr, \"panic: C++ exception: %s\\n\", what);\n    std::exit(101);\n}\n\n// the object behind a handle (Volt holds a class that isn't trivially copyable by pointer)\ntemplate <class T>\nstatic T &volt_cpp_obj(void *p) {\n    if (!p) {\n        std::fprintf(stderr, \"panic: a C++ object Volt holds by handle was never made (its handle is empty)\\n\");\n        std::exit(101);\n    }\n    return *(T *)p;\n}\n\n// Volt's str and T[..]\nstruct volt_str {\n    const unsigned char *ptr;\n    size_t len;\n};\n\ntemplate <class T>\nstruct volt_slice {\n    T *ptr;\n    size_t len;\n};\n\n// text copied out of C++, in memory the Volt side frees (std::free); and a view's bytes\nstatic inline volt_str volt_cpp_dup(const char *s, size_t n) {\n    unsigned char *p = (unsigned char *)std::malloc(n ? n : 1);\n    if (!p) {\n        volt_cpp_throw(\"out of memory\");\n    }\n    std::memcpy(p, s, n);\n    volt_str r = {p, n};\n    return r;\n}\n\nstatic inline volt_str volt_cpp_view(const char *s, size_t n) {\n    volt_str r = {(const unsigned char *)s, n};\n    return r;\n}\n\n#if __cplusplus >= 201703L\nstatic inline volt_str volt_cpp_dup(std::string_view s) {\n    return volt_cpp_dup(s.data(), s.size());\n}\n\nstatic inline volt_str volt_cpp_view(std::string_view s) {\n    return volt_cpp_view(s.data(), s.size());\n}\n#else\nstatic inline volt_str volt_cpp_dup(const std::string &s) {\n    return volt_cpp_dup(s.data(), s.size());\n}\n\nstatic inline volt_str volt_cpp_dup(const char *s) {\n    return volt_cpp_dup(s, std::strlen(s));\n}\n\nstatic inline volt_str volt_cpp_view(const std::string &s) {\n    return volt_cpp_view(s.data(), s.size());\n}\n\nstatic inline volt_str volt_cpp_view(const char *s) {\n    return volt_cpp_view(s, std::strlen(s));\n}\n#endif\n\n// a std::vector's elements copied out the same way\ntemplate <class T>\nstatic volt_slice<T> volt_cpp_dup_vec(const std::vector<T> &v) {\n#if __cplusplus >= 201103L\n    static_assert(std::is_trivially_copyable<T>::value, \"Volt copies out a std::vector of plain values\");\n#endif\n    T *p = (T *)std::malloc(sizeof(T) * (v.size() ? v.size() : 1));\n    if (!p) {\n        volt_cpp_throw(\"out of memory\");\n    }\n    std::copy(v.begin(), v.end(), p);\n    volt_slice<T> r = {p, v.size()};\n    return r;\n}\n\n#if __cplusplus >= 201103L\n// std::function and Volt: a Volt fn(...) value is its function (taking the env first) and its env;\n// what a Volt function takes and gives for a C++ type (text as volt_str, an enum as its integer)\nstruct volt_fnval {\n    void *fn;\n    void *env;\n};\n\ntemplate <class T, class = void>\nstruct volt_abi {\n    typedef T type;\n    static T in(T v) { return v; }\n    static T out(T v) { return v; }\n};\n\ntemplate <class T>\nstruct volt_abi<T, typename std::enable_if<std::is_enum<T>::value>::type> {\n    typedef typename std::underlying_type<T>::type type;\n    static type in(T v) { return (type)v; }\n    static T out(type v) { return (T)v; }\n};\n\n#if __cplusplus >= 201703L\ntemplate <>\nstruct volt_abi<std::string_view> {\n    typedef volt_str type;\n    static volt_str in(std::string_view s) { return volt_cpp_view(s); }\n};\n#endif\n\ntemplate <>\nstruct volt_abi<std::string> {\n    typedef volt_str type;\n    static volt_str in(const std::string &s) { return volt_cpp_view(s); }\n};\n\n// a call of the Volt fn f, giving R (or nothing)\ntemplate <class R, class... A>\nstruct volt_call {\n    static R run(volt_fnval f, A... a) {\n        typedef typename volt_abi<R>::type (*Fn)(void *, typename volt_abi<typename std::decay<A>::type>::type...);\n        return volt_abi<R>::out(((Fn)f.fn)(f.env, volt_abi<typename std::decay<A>::type>::in(a)...));\n    }\n};\n\ntemplate <class... A>\nstruct volt_call<void, A...> {\n    static void run(volt_fnval f, A... a) {\n        ((void (*)(void *, typename volt_abi<typename std::decay<A>::type>::type...))f.fn)(f.env, volt_abi<typename std::decay<A>::type>::in(a)...);\n    }\n};\n\n// a Volt fn value (at p) as a std::function\ntemplate <class R, class... A>\nstatic std::function<R(A...)> volt_cpp_fn(void *p) {\n    volt_fnval f = *(volt_fnval *)p;\n    return [f](A... a) -> R { return volt_call<R, A...>::run(f, a...); };\n}\n\n// a std::function C++ gave Volt (stdcxx::function), and its callable for one signature (sig: that\n// signature's tag)\ntemplate <class S>\nstruct volt_sig {\n    static char tag;\n};\n\ntemplate <class S>\nchar volt_sig<S>::tag = 0;\n\nstruct volt_fn_box {\n    const void *sig;\n    explicit volt_fn_box(const void *s) : sig(s) {}\n    virtual ~volt_fn_box() = default;\n};\n\ntemplate <class S>\nstruct volt_fn_holder : volt_fn_box {\n    std::function<S> f;\n    volt_fn_holder(std::function<S> g) : volt_fn_box(&volt_sig<S>::tag), f(std::move(g)) {}\n};\n\ntemplate <class S>\nstatic std::function<S> &volt_cpp_holder(void *p) {\n    volt_fn_box *b = (volt_fn_box *)p;\n    volt_fn_holder<S> *h = b && b->sig == &volt_sig<S>::tag ? static_cast<volt_fn_holder<S> *>(b) : nullptr;\n    if (!h) {\n        std::fprintf(stderr, \"panic: a stdcxx::function called with another signature's arguments, or empty\\n\");\n        std::exit(101);\n    }\n    return h->f;\n}\n#endif\n\n// try_ forms: run the call; when it throws, which exception (kinds numbers it, 0 is none) and\n// what it said (volt_cpp_last), instead of stopping\nstatic VOLT_TLS std::string volt_cpp_last;\n\n#if __cplusplus >= 201103L\ntemplate <class F>\nstatic int volt_cpp_try(int (*kinds)(), F f) {\n    try {\n        f();\n        return 0;\n    } catch (...) {\n        return kinds();\n    }\n}\n\n#define VOLT_CPP_TRY(KINDS, ...) volt_cpp_try(KINDS, [&]() { __VA_ARGS__; })\n#else\n// a statement expression (GCC's and clang's) where there are no lambdas\n#define VOLT_CPP_TRY(KINDS, ...) __extension__({ int volt_k_ = 0; try { __VA_ARGS__; } catch (...) { volt_k_ = KINDS(); } volt_k_; })\n#endif\n\n// a handle's object for a by-value parameter: moved from when the handle owns it, copied when it\n// only borrows it (as_Base's: the object is something else's)\nstruct volt_handle {\n    void *cpp;\n    bool borrowed;\n};\n\n#if __cplusplus >= 201103L\ntemplate <class T>\nstatic T volt_cpp_copy(T &o, std::true_type) {\n    return o;\n}\n\ntemplate <class T>\nstatic T volt_cpp_copy(T &, std::false_type) {\n    std::fprintf(stderr, \"panic: a borrowed C++ object passed by value, and it can't be copied\\n\");\n    std::exit(101);\n}\n#endif\n\ntemplate <class T>\nstatic T volt_cpp_take(void *h) {\n    volt_handle *v = (volt_handle *)h;\n    T &o = volt_cpp_obj<T>(v->cpp);\n#if __cplusplus >= 201103L\n    if (v->borrowed) {\n        return volt_cpp_copy(o, std::is_copy_constructible<T>());\n    }\n    return std::move(o);\n#else\n    return o; // no moves before C++11: copied either way\n#endif\n}\n\n// what needs RTTI: an object's dynamic type's name, a cast to a derived class (without RTTI they stop\n// the program, when called)\nVOLT_NORETURN static void volt_cpp_no_rtti(const char *what) {\n    std::fprintf(stderr, \"panic: %s needs RTTI, and the C++ was built without it (-fno-rtti)\\n\", what);\n    std::exit(101);\n}\n\ntemplate <class D, class B>\nstatic D *volt_cpp_down(B *p) {\n#if VOLT_RTTI\n    return dynamic_cast<D *>(p);\n#else\n    volt_cpp_no_rtti(\"a cast to a derived class (as_)\");\n#endif\n}\n\nstatic inline std::string volt_cpp_demangle(const char *name);\n\ntemplate <class T>\nstatic std::string volt_cpp_type_name(const T &o) {\n#if VOLT_RTTI\n    return volt_cpp_demangle(typeid(o).name());\n#else\n    volt_cpp_no_rtti(\"cpp_type_name\");\n#endif\n}\n\n// a type's name as C++ writes it (typeid's, demangled where the C++ library can)\nstatic inline std::string volt_cpp_demangle(const char *name) {\n#if __has_include(<cxxabi.h>)\n    int status = 0;\n    char *d = abi::__cxa_demangle(name, 0, 0, &status);\n    if (d) {\n        std::string s = d;\n        std::free(d);\n        return s;\n    }\n#endif\n    return name;\n}\n\n// Volt's subclasses of C++ classes (derive): a type spelled anywhere, the subclass behind a handle\n// (for its protected members), and the Volt side a derived object holds\n#if __cplusplus >= 201103L\ntemplate <class T>\nusing volt_id = T;\n#endif\n\ntemplate <class D, class B>\nstatic D &volt_dir_of(void *p, void *volt) {\n    B &o = volt_cpp_obj<B>(p);\n    if (volt) {\n        return static_cast<D &>(o);\n    }\n#if VOLT_RTTI\n    if (D *d = dynamic_cast<D *>(&o)) {\n        return *d;\n    }\n#endif\n    std::fprintf(stderr, \"panic: a protected member of a C++ object Volt didn't make with derive\\n\");\n    std::exit(101);\n}\n\ntemplate <class D, class B>\nstatic void *volt_dir_block(void *p) {\n#if VOLT_RTTI\n    D *d = p ? dynamic_cast<D *>((B *)p) : 0;\n    return d ? d->volt_d : 0;\n#else\n    return 0;\n#endif\n}\n";

// a C++ unit of the program: the headers of the imports compiled under its standard, and a wrapper
// for each C++ call they make (empty when they make none)
attach fn cpp_unit(this: checker&, unit: u32) -> std::string {
    var out: std::string = {};
    var any = false;
    for (u&) in this.cpp_shim_unit.items() {
        if (*u == unit) {
            any = true;
        }
    }
    if (!any) {
        return out;
    }
    out.append("// generated by voltc: the C++ this program calls (use cpp); each function wraps one call\n");
    out.append(CPP_UNIT_HEAD);
    for (i) in 0..this.cpp_includes.len {
        if (*this.cpp_include_unit.at(i) == unit) {
            out.append(*this.cpp_includes.at(i));
            out.push('\n');
        }
    }
    out.append(CPP_PRELUDE);
    for (i) in 0..this.cpp_decls.len {
        var used = false;
        for (j) in 0..this.cpp_shims.len {
            if (*this.cpp_shim_unit.at(j) == unit && contains(this.cpp_shims.at(j).as_str(), this.cpp_decl_names.at(i).as_str())) {
                used = true;
            }
        }
        if (used) {
            out.push('\n');
            out.append(this.cpp_decls.at(i).as_str());
        }
    }
    out.append("\nextern \"C\" {\n\n");
    for (j) in 0..this.cpp_shims.len {
        if (*this.cpp_shim_unit.at(j) == unit) {
            out.append(this.cpp_shims.at(j).as_str());
            out.push('\n');
        }
    }
    out.append("}\n");
    return out;
}
