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
    base_copy: bool = false;    // a subclass's copy can copy it (its copy constructor, public or
                                // protected; an abstract class's too): a derived object copies
}

// what a class type with no Volt form of its own can do, as clang says (form_of), by the protocols
// C++'s own library keeps and any library can: the Volt type that reads it
enum form_kind {
    NONE,
    OPTIONAL, // *x is its T, it tests as a bool, and it's made from a T or from nothing: T?
    TUPLE,    // std::tuple_size and get<I> (what structured bindings use): a tuple
    ARRAY,    // ...whose elements are contiguous (data()): T[N]
    VIEW,     // data() and size(), trivially copyable and a pointer and a length at most (so not
              // keeping them inside itself): T[..], or str of chars
    OWNED,    // data() and size() it owns: std::vec<T>, or std::string of chars
    VARIANT,  // std::variant_size, index() and get<I>: an enum, one variant each alternative
}

struct cpp_form {
    kind: form_kind = form_kind::NONE;
    n: u64 = 0;               // ARRAY: its length
    from_len: bool = false;   // VIEW, OWNED: made from (pointer, length)
    from_range: bool = false; // ...or from (first, last)
    from_elems: bool = false; // TUPLE: made from its elements
}

// the Volt source being written for one import: the classes, enums and class templates it declares
// (C++ qualified name -> Volt path inside the import's namespace), so types can refer to them
struct cpp_gen {
    c: checker&;
    out: std::string = {};
    note: std::string = {}; // the C++ declaration the next fn wraps, as a comment above it (hover shows it)
    // instance handles: a class type with no other Volt form (a class template's instance with
    // private state, a lambda's type, what an auto result is) held by handle, by its canonical C++
    // spelling: the Volt struct's name, how the wrappers spell the type (decltype(...) for a
    // lambda's), and those not written yet; on once the import's own declarations are settled
    instances: std::map<str, str> = {};
    inst_cpp: std::map<str, str> = {};
    inst_new: std::vec<str> = {};
    inst_count: u32 = 0;
    instancing: bool = false;
    unnamed_as: std::string = {}; // a call made per use: its result's type as the wrappers spell it
    inst_any: bool = false;       // ...whose types can be anyone's (else only the import's own)
    // class templates Volt can't lay out, held by handle as generic structs (template_handle): the
    // C++ template -> its Volt path
    tmpl_handles: std::map<str, str> = {};
    // a use naming the C++ library's own headers (<map>, <optional>): their names, by which the
    // files implementing them are the import's own (bits/stl_map.h for map)
    std_stems: std::vec<std::string> = {};
    // each class type's form (by its C++ spelling), the enums variant-likes read as, and the
    // declarations those need written with the instances
    forms: std::map<str, cpp_form> = {};
    variants: std::map<str, str> = {};
    pending: std::vec<std::string> = {};
    inst_src: std::string = {};   // the headers and clang's arguments, for the instances' traits
    inst_args: std::vec<str> = {};
    inst_tu: clang_tu = { index: null, tu: null }; // where they're asked (its preamble the headers)
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
    // a std::function field's set_ was written (so volt_cpp_closure_drop is needed)
    closures: bool = false;
    // the Volt fns reading an override's argument (virt_reader), by its C++ type
    readers: std::map<str, str> = {};
    // a foreign template's instance by its leading arguments (map<int, int>) -> the whole type a
    // header wrote that way (its defaults filled in): what Volt's name for it stands for
    defaulted: std::map<str, str> = {};
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
    // a deduction guide (template <...> map(...) -> map<...>) is clang's, not a function
    if (clang::clang_getCursorKind(c) == clang::CXCursor_FunctionTemplate && starts_with(cursor_name(c).as_str(), "<")) {
        return true;
    }
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
        // ...unless the use names the C++ library's headers: then std is its API (as stdcxx)
        return this.std_stems.len == 0;
    }
    if (!in_system(c)) {
        return false;
    }
    if (this.std_own(c)) {
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

// a declaration of the C++ library the use names (std_stems): a public name (no _Reserved one, no
// __detail namespace) in a file implementing one of the named headers (<map>: bits/stl_map.h)
attach fn std_own(this: cpp_gen&, c: clang::CXCursor) -> bool {
    if (this.std_stems.len == 0) {
        return false;
    }
    val name = cursor_name(c);
    if (clang::clang_getCursorKind(c) == clang::CXCursor_Namespace) {
        return clang::clang_Cursor_isInlineNamespace(c) != 0 || (name.len() > 0 && name.as_str()[0] != '_');
    }
    if (name.len() > 0 && name.as_str()[0] == '_') {
        return false;
    }
    val f = cursor_file(c);
    val full = f.as_str();
    var from: usize = 0;
    for (i) in 0..full.len {
        if (full[i] == '/') {
            from = i + 1;
        }
    }
    val base = full[from..full.len];
    for (st&) in this.std_stems.items() {
        if (contains(base, st.as_str())) {
            return true;
        }
    }
    return false;
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
        return this.record(t, tparams);
    }
    if (k == clang::CXType_Enum) {
        val q = cpp_qual(clang::clang_getTypeDeclaration(ct));
        val e = this.enums.get(q.as_str()) ?? return null;
        return S(*e);
    }
    return null;
}

// an imported class (geo::Shape), or an instance of an imported class template (geo::Box<i32>)
attach fn record(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> std::string? {
    val r = this.record_form(t, tparams);
    if (r) {
        return copy r;
    }
    val i = this.instance(clang::clang_getCanonicalType(t)) ?? return null;
    return S(i);
}

// a class type's Volt form as declared (a class, a class template's instance, std's smart pointers);
// t as written, where it was (foreign_instance)
attach fn record_form(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> std::string? {
    val ct = clang::clang_getCanonicalType(t);
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
    val tcur = clang::clang_getSpecializedCursorTemplate(decl);
    val tq = cpp_qual(tcur);
    if (this.templates.get(tq.as_str()) == null && !this.foreign_instance(t)) {
        return null;
    }
    val base = this.templates.get(tq.as_str()) ?? (this.tmpl_handles.get(tq.as_str()) ?? return null);
    // as many arguments as the Volt generic has (the defaulted rest are C++'s)
    // (tcur is this parse's: cursors may hold an earlier one's)
    var count = @cast<u32>(n);
    if (this.cursors.get(tq.as_str()) != null) {
        val tps = template_params(defaults_decl(tcur)) ?? return null;
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

// the class a std::unique_ptr t owns (with its default deleter, which delete matches), when Volt
// holds that class by handle
attach fn unique_of(this: cpp_gen&, t: clang::CXType) -> std::string? {
    val st = std_template(t) ?? return null;
    val ct = clang::clang_getCanonicalType(t);
    // (its size isn't known until something instantiates it: the deleter says)
    val del = std_template(clang::clang_Type_getTemplateArgumentAsType(ct, 1)) ?? return null;
    if (st.as_str() != "unique_ptr" || del.as_str() != "default_delete") {
        return null;
    }
    return this.handle_of(clang::clang_Type_getTemplateArgumentAsType(ct, 0));
}

fn cpp_bool(b: bool) -> str {
    if (b) {
        return "true";
    }
    return "false";
}

// the C++ name of a class Volt holds by handle, when t is one
attach fn handle_of(this: cpp_gen&, t: clang::CXType) -> std::string? {
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind != clang::CXType_Record) {
        return null;
    }
    val q = cpp_qual(clang::clang_getTypeDeclaration(ct));
    val tr = this.traits.get(q.as_str());
    val tc = clang::clang_getSpecializedCursorTemplate(clang::clang_getTypeDeclaration(ct));
    if (tr == null && clang::clang_Cursor_isNull(tc) == 0 && this.foreign_instance(t) && this.tmpl_handles.get(cpp_qual(tc).as_str()) != null) {
        // an instance of a class template held by handle (template_handle)
        return type_spelling(ct);
    }
    if (tr == null) {
        // a type with no Volt form of its own: an instance handle
        if (!this.instancing) {
            return null;
        }
        val none: std::vec<str> = {};
        if (this.record_form(t, &none) != null) {
            return null;
        }
        val vn = this.instance(ct) ?? return null;
        return S(*(this.inst_cpp.get(type_spelling(ct).as_str()) ?? return null));
    }
    if (tr->trivial) {
        return null;
    }
    return q;
}

// is class c (or the template it's an instance of) declared in the import's own headers: a local
// header, or one under a root the use names (not the C++ library's, nor another library's)
attach fn own_type(this: cpp_gen&, c: clang::CXCursor) -> bool {
    var d = c;
    val t = clang::clang_getSpecializedCursorTemplate(c);
    if (clang::clang_Cursor_isNull(t) == 0) {
        d = t;
    }
    if (!in_system(d) || this.std_own(d)) {
        return true;
    }
    val f = cursor_file(d);
    for (r&) in this.roots.items() {
        if ((ends_with(r.as_str(), "/") && starts_with(f.as_str(), r.as_str())) || f.as_str() == r.as_str()) {
            return true;
        }
    }
    return false;
}

// the Volt struct holding class type ct by handle, made the first time (written by
// flush_instances): for a type the import's declarations give no other form
attach fn instance(this: cpp_gen&, ct: clang::CXType) -> str? {
    if (!this.instancing || ct.kind != clang::CXType_Record) {
        return null;
    }
    val sp = type_spelling(ct);
    val have = this.instances.get(sp.as_str());
    if (have) {
        return *have;
    }
    // a class's private or protected type isn't one the wrappers can name; and what the import's
    // declarations reach only gets an instance for its own types (std's and other libraries' come
    // through calls made per use)
    val decl = clang::clang_getTypeDeclaration(ct);
    if (!this.inst_any) {
        if (!this.own_type(decl)) {
            return null;
        }
        // a template Volt declares a generic for isn't one: an instance of it that has no Volt form
        // is for its own reason (a non-type argument, a type of no form)
        val tc = clang::clang_getSpecializedCursorTemplate(decl);
        if (clang::clang_Cursor_isNull(tc) == 0 && this.templates.get(cpp_qual(tc).as_str()) != null) {
            return null;
        }
    }
    val access = clang::clang_getCXXAccessSpecifier(decl);
    if (access == clang::CX_CXXPrivate || access == clang::CX_CXXProtected) {
        return null;
    }
    var cpp = copy sp;
    if (contains(sp.as_str(), "(lambda at") || contains(sp.as_str(), "(unnamed") || contains(sp.as_str(), "(anonymous")) {
        // C++ can't name it: only as what a call per use gives (decltype of the call)
        if (this.unnamed_as.len() == 0) {
            return null;
        }
        cpp = copy this.unnamed_as;
    }
    var base = cursor_name(clang::clang_getTypeDeclaration(ct));
    if (base.len() == 0 || contains(sp.as_str(), "(lambda at")) {
        base = S("lambda");
    }
    var vn = vname(base.as_str());
    vn.append(fmt("_{}", unum(@cast<u64>(this.inst_count))).as_str());
    this.inst_count += 1;
    val key = this.c.intern(copy sp);
    val ck = this.c.intern(move cpp);
    this.instances.put(key, this.c.intern(move vn));
    this.inst_cpp.put(key, ck);
    // what clang says it can do (result() and param() ask, by the C++ spelling handle_of gives):
    // asked ahead for the import's own (pre_instances), else now
    if (this.traits.get(ck) == null) {
        this.traits.put(ck, this.inst_traits(ck));
    }
    put(&this.inst_new, key);
    return *(this.instances.get(key) ?? return null);
}

// the instances the import's declarations will need (their functions' parameters and results,
// fields, aliases), their traits asked of clang in one parse: one parse each is slow when a
// library has hundreds (glm's vec and mat)
attach fn pre_instances(this: cpp_gen&, root: clang::CXCursor) -> void {
    var found: std::vec<std::string> = {};
    var seen: std::map<str, bool> = {};
    this.pre_walk(root, &found, &seen, 0);
    if (found.len == 0) {
        return;
    }
    var text = copy this.inst_src;
    text.append(CPP_PROBE_HEAD);
    text.append("namespace volt_inst {\n");
    for (i) in 0..found.len {
        val n = unum(@cast<u64>(i));
        val cpp = found.at(i).as_str();
        text.append(fmt2("static const bool d{} = __is_destructible({});\n", copy n, S(cpp)).as_str());
        text.append(fmt3("static const bool c{} = __is_constructible({}, const {} &);\n", copy n, S(cpp), S(cpp)).as_str());
        text.append(fmt3("static const bool m{} = __is_constructible({}, {} &&);\n", copy n, S(cpp), S(cpp)).as_str());
        text.append(fmt2("static const bool n{} = __is_constructible({});\n", copy n, S(cpp)).as_str());
    }
    text.append("}\n");
    var trs: std::vec<cpp_traits> = {};
    for (i) in 0..found.len {
        put(&trs, {});
    }
    val tu = clang_parse("volt_cpp_inst.cpp", text.as_str(), &this.inst_args);
    if (tu.tu == null) {
        return;
    }
    for (ns&) in children(tu.root()).items() {
        if (clang::clang_getCursorKind(*ns) != clang::CXCursor_Namespace || cursor_name(*ns).as_str() != "volt_inst") {
            continue;
        }
        for (v&) in children(*ns).items() {
            val w = cursor_name(*v);
            if (w.len() < 2) {
                continue;
            }
            val i = hole_index(w.as_str()[1..w.len()]) ?? continue;
            if (i >= trs.len) {
                continue;
            }
            var yes = false;
            val ev = clang::clang_Cursor_Evaluate(*v);
            if (ev != null) {
                yes = clang::clang_EvalResult_getKind(ev) == clang::CXEval_Int && clang::clang_EvalResult_getAsInt(ev) != 0;
                clang::clang_EvalResult_dispose(ev);
            }
            val which = w.as_str()[0..1];
            if (which == "d") {
                trs.at(i)->destructible = yes;
            } else if (which == "c") {
                trs.at(i)->copyable = yes;
            } else if (which == "m") {
                trs.at(i)->movable = yes;
            } else if (which == "n") {
                trs.at(i)->defaults = yes;
            }
        }
    }
    for (i) in 0..found.len {
        this.traits.put(this.c.intern(copy *found.at(i)), *trs.at(i));
    }
}

// pre_instances' walk: the types in c's declarations (the import's own) an instance would hold
attach fn pre_walk(this: cpp_gen&, c: clang::CXCursor, found: std::vec<std::string>&, seen: std::map<str, bool>&, depth: u32) -> void {
    if (depth > 64) {
        return;
    }
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_Namespace || k == clang::CXCursor_ClassDecl || k == clang::CXCursor_StructDecl || k == clang::CXCursor_ClassTemplate) {
            if (!in_system(*ch) || this.own_type(*ch) || k == clang::CXCursor_Namespace) {
                this.pre_walk(*ch, found, seen, depth + 1);
            }
            continue;
        }
        if (in_system(*ch) && !this.own_type(*ch)) {
            continue;
        }
        if (k == clang::CXCursor_FunctionDecl || k == clang::CXCursor_CXXMethod || k == clang::CXCursor_Constructor) {
            this.pre_type(clang::clang_getCursorResultType(*ch), found, seen);
            for (p&) in params_of(*ch).items() {
                this.pre_type(clang::clang_getCursorType(*p), found, seen);
            }
        } else if (k == clang::CXCursor_FieldDecl || k == clang::CXCursor_VarDecl) {
            this.pre_type(clang::clang_getCursorType(*ch), found, seen);
        } else if (k == clang::CXCursor_TypedefDecl || k == clang::CXCursor_TypeAliasDecl) {
            this.pre_type(clang::clang_getTypedefDeclUnderlyingType(*ch), found, seen);
        }
    }
}

// t (under its references and pointers), when it would be an instance: recorded once
attach fn pre_type(this: cpp_gen&, t: clang::CXType, found: std::vec<std::string>&, seen: std::map<str, bool>&) -> void {
    var ct = clang::clang_getCanonicalType(t);
    while (ct.kind == clang::CXType_LValueReference || ct.kind == clang::CXType_RValueReference || ct.kind == clang::CXType_Pointer) {
        ct = clang::clang_getCanonicalType(clang::clang_getPointeeType(ct));
    }
    if (ct.kind != clang::CXType_Record) {
        return;
    }
    val sp = type_spelling(ct);
    if (seen.get(sp.as_str()) != null || contains(sp.as_str(), "(lambda at") || contains(sp.as_str(), "(unnamed") || contains(sp.as_str(), "(anonymous")) {
        return;
    }
    seen.put(this.c.intern(copy sp), true);
    val decl = clang::clang_getTypeDeclaration(ct);
    val tc = clang::clang_getSpecializedCursorTemplate(decl);
    if (clang::clang_Cursor_isNull(tc) == 0 && this.tmpl_handles.get(cpp_qual(tc).as_str()) != null) {
        put(found, move sp); // a generic handle's instance (std::map<int, int>)
        return;
    }
    if (this.traits.get(cpp_qual(decl).as_str()) != null || !this.own_type(decl)) {
        return;
    }
    val access = clang::clang_getCXXAccessSpecifier(decl);
    if (access == clang::CX_CXXPrivate || access == clang::CX_CXXProtected) {
        return;
    }
    val none: std::vec<str> = {};
    if (this.record_form(ct, &none) != null) {
        return;
    }
    put(found, move sp);
}

// a handle class's traits by its C++ spelling, asked of clang the first time (a generic handle's
// instance: std::map<int, int>)
attach fn ensure_traits(this: cpp_gen&, hc: str) -> void {
    if (this.traits.get(hc) == null && this.inst_args.len > 0) {
        this.traits.put(this.c.intern(S(hc)), this.inst_traits(hc));
    }
}

// what class type t can do (cpp_form), asked of clang once a type in one parse; only a class
// template's instance the import doesn't declare a form for (its elements are its type arguments)
attach fn form_of(this: cpp_gen&, t: clang::CXType) -> cpp_form {
    // (libclang gives a const one no template arguments)
    val ct = clang::clang_getUnqualifiedType(clang::clang_getCanonicalType(t));
    val none: cpp_form = {};
    if (ct.kind != clang::CXType_Record || this.inst_args.len == 0) {
        return none;
    }
    val n = clang::clang_Type_getNumTemplateArguments(ct);
    if (n <= 0 || clang::clang_Type_getTemplateArgumentAsType(ct, 0).kind == clang::CXType_Invalid) {
        return none;
    }
    val sp = type_spelling(ct);
    if (contains(sp.as_str(), "(lambda at") || contains(sp.as_str(), "(unnamed") || contains(sp.as_str(), "(anonymous") || contains(sp.as_str(), "type-parameter")) {
        return none;
    }
    val have = this.forms.get(sp.as_str());
    if (have) {
        return *have;
    }
    val decl = clang::clang_getTypeDeclaration(ct);
    val tc = clang::clang_getSpecializedCursorTemplate(decl);
    if (this.classes.get(cpp_qual(decl).as_str()) != null || (clang::clang_Cursor_isNull(tc) == 0 && this.templates.get(cpp_qual(tc).as_str()) != null)) {
        this.forms.put(this.c.intern(copy sp), none);
        return none;
    }
    var text = copy this.inst_src;
    text.append(CPP_PROBE_HEAD);
    text.append(CPP_FORM_HEAD);
    text.append("namespace volt_form_q {\n");
    text.append(fmt("typedef {} x;\n", copy sp).as_str());
    var types: std::vec<bool> = {};
    for (j) in 0..@cast<u32>(n) {
        val a = clang::clang_Type_getTemplateArgumentAsType(ct, j);
        put(&types, a.kind != clang::CXType_Invalid);
        if (a.kind != clang::CXType_Invalid) {
            text.append(fmt2("typedef {} a{};\n", type_spelling(clang::clang_getCanonicalType(a)), unum(@cast<u64>(j))).as_str());
        }
    }
    text.append(CPP_FORM_PROBE);
    var made = S("    tc = __is_constructible(x");
    for (j) in 0..types.len {
        if (*types.at(j)) {
            made.append(fmt(", a{} &", unum(@cast<u64>(j))).as_str());
        }
    }
    made.append("),\n");
    text.append(made.as_str());
    for (j) in 0..types.len {
        if (*types.at(j)) {
            val js = unum(@cast<u64>(j));
            text.append(fmt3("    t{} = __is_same(volt_form::telem<{}, x>::type, a{}),\n", copy js, copy js, copy js).as_str());
            text.append(fmt3("    w{} = __is_same(volt_form::valt<{}, x>::type, a{}),\n", copy js, copy js, copy js).as_str());
        }
    }
    text.append("};\n}\n");
    val main = "volt_cpp_form.cpp";
    if (this.inst_tu.tu == null || !this.inst_tu.reparse(main, text.as_str())) {
        this.inst_tu = clang_parse_opts(main, text.as_str(), &this.inst_args, 260);
    }
    var f: cpp_form = {};
    if (this.inst_tu.tu == null || this.inst_tu.errors_text(main) != null) {
        this.forms.put(this.c.intern(copy sp), f);
        return f;
    }
    var vals: std::map<str, i64> = {};
    for (ns&) in children(this.inst_tu.root()).items() {
        if (clang::clang_getCursorKind(*ns) != clang::CXCursor_Namespace || cursor_name(*ns).as_str() != "volt_form_q") {
            continue;
        }
        for (e&) in children(*ns).items() {
            if (clang::clang_getCursorKind(*e) == clang::CXCursor_EnumDecl) {
                for (k&) in children(*e).items() {
                    vals.put(this.c.intern(cursor_name(*k)), clang::clang_getEnumConstantDeclValue(*k));
                }
            }
        }
    }
    val tn = flag(&vals, "t");
    val wn = flag(&vals, "w");
    // a tuple's or variant's elements are its type arguments, all of them
    var tuple = tn == @cast<i64>(n);
    var variant = wn == @cast<i64>(n);
    for (j) in 0..types.len {
        val js = unum(@cast<u64>(j));
        tuple = tuple && *types.at(j) && flag(&vals, fmt("t{}", copy js).as_str()) != 0;
        variant = variant && *types.at(j) && flag(&vals, fmt("w{}", copy js).as_str()) != 0;
    }
    val seq = flag(&vals, "s") != 0;
    if (seq && tn > 0) {
        f.kind = form_kind::ARRAY;
        f.n = @cast<u64>(tn);
    } else if (tuple && tn >= 2) {
        f.kind = form_kind::TUPLE;
        f.from_elems = flag(&vals, "tc") != 0;
    } else if (variant && wn >= 1) {
        f.kind = form_kind::VARIANT;
    } else if (flag(&vals, "o") != 0) {
        f.kind = form_kind::OPTIONAL;
    } else if (seq) {
        f.kind = form_kind::OWNED;
        if (flag(&vals, "v") != 0) {
            f.kind = form_kind::VIEW;
        }
        f.from_len = flag(&vals, "fl") != 0;
        f.from_range = flag(&vals, "fr") != 0;
    }
    this.forms.put(this.c.intern(copy sp), f);
    return f;
}

// form_of's answer k (0 when clang gave none)
fn flag(vals: std::map<str, i64>&, k: str) -> i64 {
    val v = vals.get(k) ?? return 0;
    return *v;
}

fn is_char(t: clang::CXType) -> bool {
    val k = clang::clang_getCanonicalType(t).kind;
    return k == clang::CXType_Char_S || k == clang::CXType_Char_U;
}

// the Volt type of a value a form copies across: a number, bool, enum, pointer, or a class Volt
// holds by value
attach fn plain(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> std::string? {
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind == clang::CXType_LValueReference || ct.kind == clang::CXType_RValueReference) {
        return null;
    }
    if (ct.kind == clang::CXType_Record) {
        val rf = this.record_form(ct, tparams) ?? return null;
        if (starts_with(rf.as_str(), "stdcxx::") || this.handle_of(ct) != null) {
            return null;
        }
        return copy rf;
    }
    val v = this.vtype(t, tparams) ?? return null;
    if (ends_with(v.as_str(), "?")) {
        return null;
    }
    return copy v;
}

// a result of a type with a form: how it comes back as that Volt type
attach fn form_result(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> cpp_ret? {
    val f = this.form_of(t);
    if (f.kind == form_kind::NONE) {
        return null;
    }
    val ct = clang::clang_getUnqualifiedType(clang::clang_getCanonicalType(t));
    val a0 = clang::clang_Type_getTemplateArgumentAsType(ct, 0);
    if ((f.kind == form_kind::VIEW || f.kind == form_kind::OWNED) && is_char(a0)) {
        if (f.kind == form_kind::VIEW) {
            return { vty: S("str"), way: ret_way::VIEW, conv: S("volt_cpp_seq_view") };
        }
        return { vty: S("std::string"), way: ret_way::STRING, conv: S("volt_cpp_seq_dup") };
    }
    var elems: std::vec<std::string> = {};
    var count: u32 = 1;
    if (f.kind == form_kind::TUPLE || f.kind == form_kind::VARIANT) {
        count = @cast<u32>(clang::clang_Type_getNumTemplateArguments(ct));
    }
    for (j) in 0..count {
        put(&elems, this.plain(clang::clang_Type_getTemplateArgumentAsType(ct, j), tparams) ?? return null);
    }
    val e = copy *elems.at(0);
    match (f.kind) {
        .OPTIONAL => {
            // (a Volt T*? is the pointer itself, null for none: a C++ optional of a null pointer isn't that)
            if (ends_with(e.as_str(), "*")) {
                return null;
            }
            return { vty: fmt("{}?", copy e), way: ret_way::OPTIONAL, object: true, elems: move elems };
        },
        .ARRAY => { return { vty: fmt2("{}[{}]", copy e, unum(f.n)), way: ret_way::ARRAY, object: true, elems: move elems }; },
        .VIEW => { return { vty: fmt("{}[..]", copy e), conv: S("volt_cpp_seq_view") }; },
        .OWNED => { return { vty: fmt("std::vec<{}>", copy e), way: ret_way::VECTOR, elem: copy e, conv: S("volt_cpp_seq_dup") }; },
        .TUPLE => {
            var vty = S("(");
            for (j) in 0..elems.len {
                if (j > 0) {
                    vty.append(", ");
                }
                vty.append(elems.at(j).as_str());
            }
            vty.push(')');
            return { vty: move vty, way: ret_way::TUPLE, object: true, elems: move elems };
        },
        .VARIANT => {
            val vn = this.variant_enum(ct, &elems);
            return { vty: S(vn), way: ret_way::VARIANT, object: true, elems: move elems };
        },
        default => { return null; },
    }
}

// the enum a variant-like reads as: one variant each alternative, named after its type
// (I32, F64, a class's name), declared with the instances
attach fn variant_enum(this: cpp_gen&, ct: clang::CXType, elems: std::vec<std::string>&) -> str {
    val sp = type_spelling(ct);
    val have = this.variants.get(sp.as_str());
    if (have) {
        return *have;
    }
    var vn = vname(cursor_name(clang::clang_getTypeDeclaration(ct)).as_str());
    vn.append(fmt("_{}", unum(@cast<u64>(this.inst_count))).as_str());
    this.inst_count += 1;
    val cases = case_names(elems);
    var text = fmt("// C++'s {}: an enum, one variant each alternative\n", copy sp);
    text.append(fmt("enum {}: u32 {{\n", copy vn).as_str());
    for (j) in 0..elems.len {
        text.append(fmt2("    {}: {},\n", copy *cases.at(j), copy *elems.at(j)).as_str());
    }
    text.append("}\n");
    put(&this.pending, move text);
    val name = this.c.intern(move vn);
    this.variants.put(this.c.intern(move sp), name);
    return name;
}

// a variant-like's variants: each alternative's Volt type, in capitals (geo::Vec2 is VEC2, i32* is
// I32_PTR), with its index after it when two would be the same
fn case_names(elems: std::vec<std::string>&) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    for (j) in 0..elems.len {
        val last = last_part(elems.at(j).as_str(), elems.at(j).as_str());
        var c: std::string = {};
        for (ch) in last.as_str() {
            if (ch == '*') {
                c.append("_PTR");
            } else if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_') {
                if (ch >= 'a' && ch <= 'z') {
                    c.push(ch - 32);
                } else {
                    c.push(ch);
                }
            }
        }
        for (k) in 0..out.len {
            if (out.at(k).as_str() == c.as_str()) {
                c.append(fmt("_{}", unum(@cast<u64>(j))).as_str());
                break;
            }
        }
        put(&out, move c);
    }
    return out;
}

// a parameter of a type with a form: the Volt value it reads as, made into the C++ object
attach fn form_param(this: cpp_gen&, base: clang::CXType, name: str, slot: str, tparams: std::vec<str>&) -> cpp_arg? {
    val f = this.form_of(base);
    if (f.kind == form_kind::NONE) {
        return null;
    }
    val ct = clang::clang_getUnqualifiedType(clang::clang_getCanonicalType(base));
    val x = S(strip_const(type_spelling(ct).as_str()));
    val a0 = clang::clang_Type_getTemplateArgumentAsType(ct, 0);
    val a0s = type_spelling(clang::clang_getCanonicalType(a0));
    if (f.kind == form_kind::VIEW || f.kind == form_kind::OWNED) {
        var vty = S("str");
        if (!is_char(a0)) {
            vty = fmt("{}[..]", this.plain(a0, tparams) ?? return null);
        }
        if (f.from_len) {
            return { vty: move vty, pass: S(name), cpp: fmt4("{}(({} *){}.ptr, {}.len)", copy x, copy a0s, S(slot), S(slot)) };
        }
        if (f.from_range) {
            var c = fmt4("{}(({} *){}.ptr, ({} *)", copy x, copy a0s, S(slot), copy a0s);
            c.append(fmt2("{}.ptr + {}.len)", S(slot), S(slot)).as_str());
            return { vty: move vty, pass: S(name), cpp: move c };
        }
        return null;
    }
    if (f.kind == form_kind::TUPLE || f.kind == form_kind::VARIANT) {
        // read from the Volt value's fields where C lays them out (a tuple's in order; an enum's
        // u32 tag, then its variant's value)
        if (f.kind == form_kind::TUPLE && !f.from_elems) {
            return null;
        }
        var elems: std::vec<std::string> = {};
        var types = S("");
        for (j) in 0..@cast<u32>(clang::clang_Type_getNumTemplateArguments(ct)) {
            val a = clang::clang_Type_getTemplateArgumentAsType(ct, j);
            put(&elems, this.plain(a, tparams) ?? return null);
            types.append(", ");
            types.append(strip_const(type_spelling(clang::clang_getCanonicalType(a)).as_str()));
        }
        if (f.kind == form_kind::VARIANT) {
            val vn = this.variant_enum(ct, &elems);
            return { vty: S(vn), pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt3("volt_variant_in<{}{} >({})", copy x, move types, S(slot)) };
        }
        var vty = S("(");
        var c = fmt("{}(", copy x);
        for (j) in 0..elems.len {
            if (j > 0) {
                vty.append(", ");
                c.append(", ");
            }
            vty.append(elems.at(j).as_str());
            c.append(fmt3("volt_tuple_at<{}{} >({})", unum(@cast<u64>(j)), copy types, S(slot)).as_str());
        }
        vty.push(')');
        c.push(')');
        return { vty: move vty, pass: fmt("@cast<void*>(&{})", S(name)), cpp: move c };
    }
    match (f.kind) {
        .ARRAY => {
            val e = this.plain(a0, tparams) ?? return null;
            return { vty: fmt2("{}[{}]", copy e, unum(f.n)), pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt2("volt_cpp_copy_in<{} >({})", copy x, S(slot)) };
        },
        .OPTIONAL => {
            val e = this.plain(a0, tparams) ?? return null;
            if (ends_with(e.as_str(), "*")) {
                return null;
            }
            return { vty: fmt("{}?", copy e), pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt3("volt_cpp_opt_in<{}, {} >({})", copy x, S(strip_const(a0s.as_str())), S(slot)) };
        },
        default => { return null; },
    }
}

// how many of @cpp's arguments a C++ expression uses ({i}, {&i}, {=i}): where the next one goes
fn holes_used(cpp: str) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cpp.len) {
        if (cpp[i] == '{') {
            var e = i + 1;
            while (e < cpp.len && cpp[e] != '}') {
                e += 1;
            }
            var h = cpp[i + 1..e];
            if (h.len > 0 && (h[0] == '&' || h[0] == '=')) {
                h = h[1..h.len];
            }
            val k = hole_index(h);
            if (k != null && (k ?? 0) + 1 > n) {
                n = (k ?? 0) + 1;
            }
            i = e;
        }
        i += 1;
    }
    return n;
}

// an instance of another library's class template Volt names by the template (foreign_template): not
// text (str's), every argument a type that comes back to C++ as itself (a char is Volt's i8, which
// is C++'s signed char), and the arguments Volt leaves out its defaults: the header wrote only the
// leading ones (t as written), or the whole type is one a header wrote that way. Any other stays an
// instance handle, spelled as C++ does (a std::map with std::greater)
attach fn foreign_instance(this: cpp_gen&, t: clang::CXType) -> bool {
    val ct = clang::clang_getCanonicalType(t);
    if (char_text(ct, "basic_string") || char_text(ct, "basic_string_view")) {
        return false;
    }
    val tc = clang::clang_getSpecializedCursorTemplate(clang::clang_getTypeDeclaration(ct));
    if (clang::clang_Cursor_isNull(tc) != 0 || !this.foreign_template(tc)) {
        return false;
    }
    // the arguments Volt passes (the defaulted rest are C++'s; tc is this parse's, cursors may have
    // an earlier one's)
    val tps = template_params(defaults_decl(tc)) ?? return false;
    var n = clang::clang_Type_getNumTemplateArguments(ct);
    if (@cast<i32>(tps.len) < n) {
        n = @cast<i32>(tps.len);
    }
    var key = cpp_qual(tc);
    for (i) in 0..@cast<u32>(if (n > 0) n else 0) {
        val a = clang::clang_Type_getTemplateArgumentAsType(ct, i);
        if (!round_trips(a, 0)) {
            return false;
        }
        key.push('|');
        key.append(type_spelling(clang::clang_getCanonicalType(a)).as_str());
    }
    if (clang::clang_Type_getNumTemplateArguments(ct) <= n) {
        return true;
    }
    // (as written: a template-id's own arguments, through typedefs; a canonical type's are all)
    val full = type_spelling(ct);
    if (clang::clang_Type_getNumTemplateArguments(t) <= n) {
        this.defaulted.put(this.c.intern(copy key), this.c.intern(copy full));
        return true;
    }
    val known = this.defaulted.get(key.as_str()) ?? return false;
    return *known == full.as_str();
}

// what reference or pointer t refers to, as written (through a typedef of one: as clang has it)
fn pointee(t: clang::CXType) -> clang::CXType {
    if (t.kind == clang::CXType_LValueReference || t.kind == clang::CXType_RValueReference || t.kind == clang::CXType_Pointer) {
        return clang::clang_getPointeeType(t);
    }
    return clang::clang_getPointeeType(clang::clang_getCanonicalType(t));
}

// class template tc's declaration that has the defaults (a redeclaration doesn't repeat them): the
// fewest parameters Volt passes
fn defaults_decl(tc: clang::CXCursor) -> clang::CXCursor {
    var dc = tc;
    var n = (template_params(tc) ?? return tc).len;
    val others: clang::CXCursor[2] = { clang::clang_getCanonicalCursor(tc), clang::clang_getCursorDefinition(tc) };
    for (o) in others {
        if (clang::clang_Cursor_isNull(o) != 0) {
            continue;
        }
        val ot = template_params(o) ?? continue;
        if (ot.len < n) {
            n = ot.len;
            dc = o;
        }
    }
    return dc;
}

// does C++ type t come back to C++ from its Volt type as itself: no plain char, wchar_t or charN_t in
// it (Volt's i8 is C++'s signed char); a value argument (no type) does
fn round_trips(t: clang::CXType, depth: u32) -> bool {
    val ct = clang::clang_getCanonicalType(t);
    val k = ct.kind;
    if (depth > 16 || k == clang::CXType_Char_S || k == clang::CXType_Char_U || k == clang::CXType_WChar || k == clang::CXType_Char16 || k == clang::CXType_Char32) {
        return false;
    }
    if (k == clang::CXType_Pointer || k == clang::CXType_LValueReference || k == clang::CXType_RValueReference) {
        return round_trips(clang::clang_getPointeeType(ct), depth + 1);
    }
    val n = clang::clang_Type_getNumTemplateArguments(ct);
    for (i) in 0..@cast<u32>(if (n > 0) n else 0) {
        if (!round_trips(clang::clang_Type_getTemplateArgumentAsType(ct, i), depth + 1)) {
            return false;
        }
    }
    return true;
}

// another library's class template one of its instances needs (the C++ library's own: std::map):
// declared once as a generic handle (template_handle) under its namespaces (std's as stdcxx, inline
// ones left out), so every instance of it is that generic's, by a name a signature can say
// (stdcxx::map<i32, f64>); whether it is one
attach fn foreign_template(this: cpp_gen&, tc: clang::CXCursor) -> bool {
    val q = cpp_qual(tc);
    if (this.tmpl_handles.get(q.as_str()) != null) {
        return true;
    }
    if (!this.instancing || clang::clang_getCursorKind(tc) != clang::CXCursor_ClassTemplate || this.templates.get(q.as_str()) != null || this.own_type(tc)) {
        return false;
    }
    val dc = defaults_decl(tc);
    val tps = template_params(dc) ?? return false;
    if (tps.len == 0) {
        return false;
    }
    // its path: namespaces and its name, none of them internal (_Ugly)
    var parts: std::vec<std::string> = {};
    var p = tc;
    while (clang::clang_getCursorKind(p) != clang::CXCursor_TranslationUnit) {
        val k = clang::clang_getCursorKind(p);
        if (k == clang::CXCursor_Namespace && clang::clang_Cursor_isInlineNamespace(p) != 0) {
            p = clang::clang_getCursorSemanticParent(p);
            continue;
        }
        if (k != clang::CXCursor_Namespace && parts.len > 0) {
            return false; // a template inside a class
        }
        val n = cursor_name(p);
        if (n.len() == 0 || n.as_str()[0] == '_') {
            return false;
        }
        put(&parts, vname(n.as_str()));
        p = clang::clang_getCursorSemanticParent(p);
    }
    val name = parts.at(0).as_str();
    if (name == "unique_ptr" || name == "shared_ptr" || name == "function") {
        return false;
    }
    var path = S("");
    var i = parts.len;
    while (i > 0) {
        i -= 1;
        var part = copy *parts.at(i);
        if (i == parts.len - 1 && part.as_str() == "std") {
            part = S("stdcxx");
        }
        if (path.len() > 0) {
            path.append("::");
        }
        path.append(part.as_str());
    }
    this.tmpl_handles.put(this.c.intern(copy q), this.c.intern(copy path));
    this.cursors.put(this.c.intern(copy q), dc);
    // written with the instances, in its namespaces
    var saved = copy this.out;
    val depth = this.depth;
    val scope = copy this.scope;
    this.out = {};
    this.depth = 0;
    this.scope = copy path;
    i = parts.len;
    while (i > 1) {
        i -= 1;
        var part = copy *parts.at(i);
        if (i == parts.len - 1 && part.as_str() == "std") {
            part = S("stdcxx");
        }
        this.line(fmt("namespace {} {{", move part).as_str());
        this.depth += 1;
    }
    this.template_handle(dc);
    while (this.depth > 0) {
        this.depth -= 1;
        this.line("}");
    }
    put(&this.pending, copy this.out);
    this.out = move saved;
    this.depth = depth;
    this.scope = copy scope;
    return true;
}

// a class template prune left out, held by handle as a generic struct: made by {} (its default
// constructor) or T::new(...), deleted and copied by C++, its members worked out per use
attach fn template_handle(this: cpp_gen&, c: clang::CXCursor) -> void {
    val q = cpp_qual(c);
    val tps = template_params(c) ?? return;
    val path = *(this.tmpl_handles.get(q.as_str()) ?? return);
    val vn = last_part(path, "");
    val gen = generics_text(&tps);
    val extra = extra_types(&tps);
    val inst = cpp_template_ref(q.as_str(), tps.len);
    var self_ty = copy vn;
    self_ty.push('<');
    for (i) in 0..tps.len {
        if (i > 0) {
            self_ty.append(", ");
        }
        self_ty.append(tps.at(i).as_str());
    }
    self_ty.push('>');
    if (!this.first_time(fmt("struct {}", copy vn).as_str(), "")) {
        return;
    }
    this.put_note();
    this.line(fmt("// C++'s {}, held by handle: its members are worked out per use", copy q).as_str());
    this.line(gen.as_str());
    this.line(fmt("@attributes([@cpp_handle(\"{}\")])", copy q).as_str());
    this.line(fmt("struct {} {{", copy vn).as_str());
    this.line(fmt2("    cpp: void* = @cpp<void*{}>(\"new {}()\");", copy extra, copy inst).as_str());
    this.line("    borrowed: bool = false;");
    this.line("}");
    this.line(gen.as_str());
    this.line(fmt("attach fn delete(this: {}&) -> void {{", copy self_ty).as_str());
    this.line("    if (this.cpp != null && !this.borrowed) {");
    this.line(fmt2("        @cpp<void{}>(\"delete ({} *){{0}}\", this.cpp);", copy extra, copy inst).as_str());
    this.line("    }");
    this.line("}");
    this.line(gen.as_str());
    this.line(fmt2("attach fn copy(this: {}&) -> {} {{", copy self_ty, copy self_ty).as_str());
    this.line("    if (this.cpp == null) {");
    this.line("        return { cpp: null };");
    this.line("    }");
    this.line(fmt3("    return {{ cpp: @cpp<void*{}>(\"new {}(*({} *){{0}})\", this.cpp) }};", copy extra, copy inst, copy inst).as_str());
    this.line("}");
}

// an instance's traits: destructible, copyable, made from nothing (held by handle, so not trivial)
attach fn inst_traits(this: cpp_gen&, cpp: str) -> cpp_traits {
    var tr: cpp_traits = {};
    var text = copy this.inst_src;
    text.append(CPP_PROBE_HEAD);
    text.append("namespace volt_inst {\nstatic const bool d = __is_destructible(");
    text.append(cpp);
    text.append(");\nstatic const bool c = __is_constructible(");
    text.append(cpp);
    text.append(", const ");
    text.append(cpp);
    text.append(" &);\nstatic const bool m = __is_constructible(");
    text.append(cpp);
    text.append(", ");
    text.append(cpp);
    text.append(" &&);\nstatic const bool n = __is_constructible(");
    text.append(cpp);
    text.append(");\n}\n");
    val main = "volt_cpp_inst.cpp";
    if (this.inst_tu.tu == null || !this.inst_tu.reparse(main, text.as_str())) {
        // CXTranslationUnit_PrecompiledPreamble | CreatePreambleOnFirstParse: the headers once
        this.inst_tu = clang_parse_opts(main, text.as_str(), &this.inst_args, 260);
    }
    if (this.inst_tu.tu == null) {
        // clang couldn't say: destructible (a wrong guess fails loudly in the wrappers, while
        // "not destructible" would leak each object quietly)
        tr.destructible = true;
        return tr;
    }
    for (ns&) in children(this.inst_tu.root()).items() {
        if (clang::clang_getCursorKind(*ns) != clang::CXCursor_Namespace || cursor_name(*ns).as_str() != "volt_inst") {
            continue;
        }
        for (v&) in children(*ns).items() {
            var yes = false;
            val ev = clang::clang_Cursor_Evaluate(*v);
            if (ev != null) {
                yes = clang::clang_EvalResult_getKind(ev) == clang::CXEval_Int && clang::clang_EvalResult_getAsInt(ev) != 0;
                clang::clang_EvalResult_dispose(ev);
            }
            val w = cursor_name(*v);
            if (w.as_str() == "d") {
                tr.destructible = yes;
            } else if (w.as_str() == "c") {
                tr.copyable = yes;
            } else if (w.as_str() == "m") {
                tr.movable = yes;
            } else if (w.as_str() == "n") {
                tr.defaults = yes;
            }
        }
    }
    return tr;
}

// text for a Volt string literal: its quotes and backslashes escaped
fn escape_str(s: str) -> std::string {
    var out: std::string = {};
    for (c) in s {
        if (c == '"' || c == '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    return out;
}

// the instance handles made since the last time: each one's struct, delete and copy, after what's
// been written
attach fn flush_instances(this: cpp_gen&) -> void {
    for (p&) in this.pending.items() {
        this.out.append(p.as_str());
    }
    this.pending = {};
    if (this.inst_new.len == 0) {
        return;
    }
    for (i) in 0..this.inst_new.len {
        val key = *this.inst_new.at(i);
        val vn = *(this.instances.get(key) ?? continue);
        val cpp = *(this.inst_cpp.get(key) ?? continue);
        val tr = *(this.traits.get(cpp) ?? continue);
        this.line(fmt("// C++'s {}: Volt holds it by handle; its methods are worked out per use", S(key)).as_str());
        this.line(fmt("@attributes([@cpp_handle(\"{}\")])", escape_str(cpp)).as_str());
        this.line(fmt("struct {} {{", S(vn)).as_str());
        if (tr.defaults && tr.destructible) {
            this.line(fmt("    cpp: void* = @cpp<void*>(\"new {}()\");", escape_str(cpp)).as_str());
        } else {
            this.line(fmt("    cpp: void* = @compile_error(\"C++'s {} can't be made from nothing\");", escape_str(key)).as_str());
        }
        this.line("    borrowed: bool = false;");
        this.line("}");
        if (tr.destructible) {
            this.line(fmt("attach fn delete(this: {}&) -> void {{", S(vn)).as_str());
            this.line("    if (this.cpp != null && !this.borrowed) {");
            this.line(fmt("        @cpp<void>(\"delete ({} *){{0}}\", this.cpp);", escape_str(cpp)).as_str());
            this.line("    }");
            this.line("}");
        }
        if (tr.copyable) {
            this.line(fmt2("attach fn copy(this: {}&) -> {} {{", S(vn), S(vn)).as_str());
            this.line("    if (this.cpp == null) {");
            this.line("        return { cpp: null };");
            this.line("    }");
            this.line(fmt2("    return {{ cpp: @cpp<void*>(\"new {}(*({} *){{0}})\", this.cpp) }};", escape_str(cpp), escape_str(cpp)).as_str());
            this.line("}");
        }
    }
    this.inst_new = {};
}

// can a getter copy a value of type t out of where it is (a field, a static member): a class, held
// by value or by handle, needs a copy constructor (a trivially copyable one may have it deleted)
attach fn copies_out(this: cpp_gen&, t: clang::CXType) -> bool {
    val ct = clang::clang_getCanonicalType(t);
    if (ct.kind != clang::CXType_Record || std_template(ct) != null) {
        return true;
    }
    val q = cpp_qual(clang::clang_getTypeDeclaration(ct));
    if (this.traits.get(q.as_str()) == null) {
        // an instance handle's, by the spelling handle_of gives
        val hc = this.handle_of(ct) ?? return true;
        this.ensure_traits(hc.as_str());
        return (this.traits.get(hc.as_str()) ?? return true)->copyable;
    }
    return (this.traits.get(q.as_str()) ?? return true)->copyable;
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
        val fp = this.form_param(base, name, slot.as_str(), tparams);
        if (fp) {
            return copy fp;
        }
        // a std::unique_ptr of a class Volt holds by handle: the handle's object, which it no
        // longer owns (a borrowed handle's copy)
        val uhc = this.unique_of(base);
        if (uhc) {
            val v = this.vtype(clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(base), 0), tparams) ?? return null;
            this.ensure_traits(uhc.as_str());
            val utr = this.traits.get(uhc.as_str());
            val rel = fmt3("volt_cpp_release<{}, {} >({})", copy uhc, S(cpp_bool(utr != null && utr->copyable)), copy slot);
            return { vty: move v, pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt2("std::unique_ptr<{} >({})", copy uhc, move rel) };
        }
    }
    // a T* of a class Volt holds by handle: a Volt H* (&h, or null)
    val pk = clang::clang_getCanonicalType(t);
    if (pk.kind == clang::CXType_Pointer) {
        val pt = clang::clang_getPointeeType(pk);
        val phc = this.handle_of(pt);
        if (phc) {
            val v = this.vtype(pt, tparams) ?? return null;
            return { vty: fmt("{}*", move v), pass: fmt("@cast<void*>({})", S(name)), cpp: fmt2("volt_cpp_ptr<{} >({})", copy phc, copy slot) };
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
        // by value or T&&: moved from when the handle owns the object, copied when it only borrows
        // it (volt_cpp_take); a T&& of a class that can be neither binds the object itself
        this.ensure_traits(hc.as_str());
        val tr = this.traits.get(hc.as_str());
        if (tr) {
            if (!tr->movable && !tr->copyable) {
                if (k != clang::CXType_RValueReference) {
                    return null;
                }
                return { vty: move vt, pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt2("VOLT_MOVE(volt_cpp_obj<{}>(((volt_handle *)({}))->cpp))", copy hc, copy slot) };
            }
        }
        return { vty: move vt, pass: fmt("@cast<void*>(&{})", S(name)), cpp: fmt3("volt_cpp_take<{}, {}>({})", copy hc, S(cpp_bool(tr == null || tr->copyable)), copy slot) };
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
    BORROWED, // a reference into C++'s object: a handle borrowing it
    POINTER,  // a T*: a borrowed handle, or none
    OWNER,    // a std::unique_ptr: an owning handle, or none
    OPTIONAL, // the forms (form_result): copied into Volt locals
    TUPLE,
    ARRAY,
    VARIANT,
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
    elems: std::vec<std::string> = {}; // a form's element types
    conv: std::string = {};            // the C++ helper making what @cpp returns (else the way's own)
}

// the Volt return type of a C++ one (a reference to a class stays one; to a const number, a copy)
attach fn result(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> cpp_ret? {
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_RValueReference) {
        // T&&: what it refers to, by value (moved into a new object for a class held by handle,
        // which needs a move or copy constructor; copied otherwise)
        val to = clang::clang_getNonReferenceType(t);
        val hc = this.handle_of(to);
        if (hc) {
            this.ensure_traits(hc.as_str());
            if (!(this.traits.get(hc.as_str()) ?? return null)->movable) {
                // one that can't be moved: borrowed, as a T& is
                val v = this.vtype(to, tparams) ?? return null;
                return { vty: move v, way: ret_way::BORROWED, object: true, cls: copy hc };
            }
        }
        return this.result(to, tparams);
    }
    // a T* of a class Volt holds by handle: a borrowed handle (C++ keeps owning the object), none
    // for nullptr
    val pk = clang::clang_getCanonicalType(t);
    if (pk.kind == clang::CXType_Pointer) {
        val pt = clang::clang_getPointeeType(pk);
        val phc = this.handle_of(pt);
        if (phc) {
            val v = this.vtype(pt, tparams) ?? return null;
            return { vty: fmt("{}?", move v), way: ret_way::POINTER, object: true, cls: copy phc };
        }
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
        val fr = this.form_result(base, tparams);
        if (fr) {
            return copy fr;
        }
        // a std::unique_ptr (its default deleter) of a class Volt holds by handle: the object,
        // released into an owning handle (none for an empty one)
        val uhc = this.unique_of(base);
        if (uhc) {
            val v = this.vtype(clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(base), 0), tparams) ?? return null;
            return { vty: fmt("{}?", move v), way: ret_way::OWNER, object: true, cls: copy uhc };
        }
    }
    // a class Volt holds by handle: a new object made from the result, a const& one copied; a
    // reference into C++'s object that can't be copied (or isn't const) is borrowed, good while
    // what it's in is
    val hc = this.handle_of(base);
    if (hc) {
        this.ensure_traits(hc.as_str());
        val tr = this.traits.get(hc.as_str()) ?? return null;
        if (t.kind == clang::CXType_LValueReference && (clang::clang_isConstQualifiedType(base) == 0 || !tr->copyable || !tr->destructible)) {
            val bv = this.vtype(base, tparams) ?? return null;
            return { vty: move bv, way: ret_way::BORROWED, object: true, cls: copy hc };
        }
        if (!tr->destructible) {
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
            base = pointee(at);
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

// C++'s operators and their Volt names (op_name's, and cpp_operator's the other way): those with one
// operand, then two
val OP_UNARY: str[7] = { "-", "+", "!", "~", "*", "++", "--" };
val OP_UNARY_NAMES: str[7] = { "op_neg", "op_pos", "op_not", "op_bitnot", "op_deref", "op_inc", "op_dec" };
val OP_BINARY: str[30] = { "+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "&&", "||", "[]", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "=" };
val OP_BINARY_NAMES: str[30] = { "op_add", "op_sub", "op_mul", "op_div", "op_rem", "op_eq", "op_ne", "op_lt", "op_le", "op_gt", "op_ge", "op_bitand", "op_bitor", "op_xor", "op_shl", "op_shr", "op_and", "op_or", "op_index", "op_add_assign", "op_sub_assign", "op_mul_assign", "op_div_assign", "op_rem_assign", "op_bitand_assign", "op_bitor_assign", "op_xor_assign", "op_shl_assign", "op_shr_assign", "assign" };

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
        for (i) in 0..7 {
            if (sym == OP_UNARY[i]) {
                return OP_UNARY_NAMES[i];
            }
        }
        return null;
    }
    if (operands != 2) {
        return null;
    }
    for (i) in 0..30 {
        if (sym == OP_BINARY[i]) {
            return OP_BINARY_NAMES[i];
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

// the C++ expression for a method call written with an operator's Volt name (.op_add on {0}): the
// operands are {0} and {1} (an operator call ends in its "(" for the arguments to follow); none
// for another name
fn cpp_operator(callee: str, nargs: usize) -> std::string? {
    if (callee == ".op_call") {
        return S("{0}(");
    }
    if (callee.len < 2 || callee[0] != '.') {
        return null;
    }
    val n = callee[1..callee.len];
    if (nargs == 0) {
        for (i) in 0..7 {
            if (n == OP_UNARY_NAMES[i]) {
                return fmt("({}{{0}})", S(OP_UNARY[i]));
            }
        }
        return null;
    }
    if (nargs != 1) {
        return null;
    }
    for (i) in 0..30 {
        if (n == OP_BINARY_NAMES[i]) {
            if (OP_BINARY[i] == "[]") {
                return S("{0}[{1}]");
            }
            return fmt("({{0}} {} {{1}})", S(OP_BINARY[i]));
        }
    }
    return null;
}

// struct sid's C++ class when it holds one by handle (@cpp_handle)
attach fn cpp_handle_of(this: checker&, sid: u32) -> str? {
    for (a&) in this.item_of(this.si(sid).decl).attrs.items() {
        if (attr_named(a, "cpp_handle")) {
            val q = attr_str(a) ?? return null;
            val args = &this.si(sid).args;
            if (args.len == 0) {
                return q;
            }
            // a generic one's instance: std::map<int32_t, int32_t>
            var out = S(q);
            out.push('<');
            for (i) in 0..args.len {
                if (i > 0) {
                    out.append(", ");
                }
                match (*args.at(i)) {
                    .TY(t) => { out.append((this.cpp_type_text(t) ?? return null).as_str()); },
                    .INT(v) => { out.append(num(v).as_str()); },
                    default => { return null; },
                }
            }
            out.append(" >");
            return this.intern(move out);
        }
    }
    return null;
}

// a Volt type's C++ type as text (a handle struct's: its class), for {tN} and template arguments
attach fn cpp_type_text(this: checker&, t: u32) -> std::string? {
    match (*this.t.get(t)) {
        .STRUCT(sid) => {
            val q = this.cpp_handle_of(sid);
            if (q) {
                return S(q);
            }
        },
        default => {},
    }
    return this.cpp_spell(t);
}

// a method a handle struct's class has that Volt didn't declare (an instance's, or one whose types
// hang on the call): clang works it out, as for a call made per use
attach fn cpp_handle_method(this: checker&, sid: u32, r: tval, name: str, gargs: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    val k = this.cpp_ctx_of(this.decls.at(@cast<usize>(this.si(sid).decl)).ns) ?? return fails(span, "this C++ class's import is gone");
    val callee = fmt(".{}", S(name));
    val v = this.cpp_use_call(k, this.intern(copy callee), false, name, r, gargs, args, want, span) catch |e| {
        return this.cpp_member_error(e, sid, name);
    };
    return v;
}

// ...a static one: Q::name(...)
attach fn cpp_handle_static(this: checker&, sid: u32, name: str, gargs: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    val k = this.cpp_ctx_of(this.decls.at(@cast<usize>(this.si(sid).decl)).ns) ?? return fails(span, "this C++ class's import is gone");
    val q = this.cpp_handle_of(sid) ?? return fails(span, "not a C++ class");
    var callee = fmt2("{}::{}", S(q), S(name));
    if (name == "new") {
        callee = S(q); // T::new(...) is a constructor's call: T(...)
    }
    val v = this.cpp_use_call(k, this.intern(copy callee), false, name, null, gargs, args, want, span) catch |e| {
        return this.cpp_member_error(e, sid, name);
    };
    return v;
}

// clang's error for a member Volt asked it to work out, said as the member's (a misspelt name is
// "no member" in C++'s words, under Volt's)
attach fn cpp_member_error(this: checker&, e: compile_error, sid: u32, name: str) -> compile_error {
    match (e) {
        .AT(d) => { return fail(d.span, fmt3("{} has no member '{}' Volt declares, so C++ worked it out: {}", S(this.si(sid).name), S(name), copy d.msg)); },
    }
}

// {} of a generic C++ handle's instance (template_handle) makes the object with its default
// constructor: an error at the literal when it has none, as for an instance handle's
attach fn cpp_can_default(this: checker&, sid: u32, span: span) -> compile_error!void {
    val q = this.cpp_handle_of(sid) ?? return;
    val k = this.cpp_ctx_of(this.decls.at(@cast<usize>(this.si(sid).decl)).ns) ?? return;
    val g = &this.cpp_ctxs.at(k).gen;
    g.ensure_traits(q);
    val tr = g.traits.get(q) ?? return;
    if (!tr->defaults || !tr->destructible) {
        return fail(span, fmt("C++'s {} can't be made from nothing: make one with T::new(...)", replace_all(q, " >", ">")));
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
        // a default argument shows up as an expression under the parameter, after its name (one in
        // its type, std::array<int, 3>'s 3, comes before)
        var has_default = false;
        for (ch&) in children(p).items() {
            if (clang::clang_isExpression(clang::clang_getCursorKind(*ch)) != 0 && cursor_offset(*ch) > cursor_offset(p)) {
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
    // a try_ form, when it can throw
    val can_try = may_throw(fn_cursor);
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
            var call_names = S("");
            for (i) in 0..count {
                if (i > 0) {
                    call_names.append(", ");
                }
                call_names.append(names.at(i).as_str());
            }
            this.try_text(generics, head, params.as_str(), &r, call_names.as_str());
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
    // a form's locals go to C++ by pointer, after the call's own arguments
    val k = holes_used(cpp);
    var holes: std::string = {};
    var ptrs: std::string = {};
    for (j) in 0..r.elems.len {
        holes.append(fmt(", {{{}}}", unum(@cast<u64>(k + j))).as_str());
        ptrs.append(fmt(", &try_{}", unum(@cast<u64>(j))).as_str());
    }
    match (r.way) {
        .PLAIN => {
            var body: std::string = {};
            if (r.vty.as_str() != "void") {
                body.append("return ");
            }
            var c = S(cpp);
            if (r.conv.len() > 0) {
                c = fmt2("{}({})", copy r.conv, move c);
            }
            body.append(fmt4("@cpp<{}{}>(\"{}\"{});", copy r.vty, S(extra), move c, S(tail)).as_str());
            this.line(body.as_str());
        },
        .VIEW => { this.line(fmt4("return @cpp<str{}>(\"{}({})\"{});", S(extra), conv_or(r, "volt_cpp_view"), S(cpp), S(tail)).as_str()); },
        .BORROWED => { this.line(fmt3("return {{ cpp: @cpp<void*{}>(\"volt_cpp_addr({})\"{}), borrowed: true }};", S(extra), S(cpp), S(tail)).as_str()); },
        .POINTER => { this.handle_or_none(fmt("(void *)({})", S(cpp)).as_str(), true, extra, tail); },
        .OWNER => { this.handle_or_none(fmt("(void *)({}).release()", S(cpp)).as_str(), false, extra, tail); },
        .OPTIONAL => {
            this.line(fmt("var try_0: {};", copy *r.elems.at(0)).as_str());
            this.line(fmt4("if (@cpp<bool{}>(\"volt_cpp_opt_out({}{})\"{}, &try_0)) {{", S(extra), S(cpp), copy holes, S(tail)).as_str());
            this.line("    return try_0;");
            this.line("}");
            this.line("return null;");
        },
        .ARRAY => {
            this.line(fmt("var try_0: {};", copy r.vty).as_str());
            this.line(fmt4("@cpp<void{}>(\"volt_cpp_copy_out({}{})\"{}, @cast<void*>(&try_0));", S(extra), S(cpp), copy holes, S(tail)).as_str());
            this.line("return try_0;");
        },
        .TUPLE => {
            var all = S("");
            for (j) in 0..r.elems.len {
                this.line(fmt2("var try_{}: {};", unum(@cast<u64>(j)), copy *r.elems.at(j)).as_str());
                if (j > 0) {
                    all.append(", ");
                }
                all.append(fmt("try_{}", unum(@cast<u64>(j))).as_str());
            }
            var call = fmt4("@cpp<void{}>(\"volt_cpp_get<0>({}{})\"{}", S(extra), S(cpp), copy holes, S(tail));
            call.append(ptrs.as_str());
            call.append(");");
            this.line(call.as_str());
            this.line(fmt("return ({});", move all).as_str());
        },
        .VARIANT => {
            for (j) in 0..r.elems.len {
                this.line(fmt2("var try_{}: {};", unum(@cast<u64>(j)), copy *r.elems.at(j)).as_str());
            }
            var call = fmt4("val try_i = @cpp<u64{}>(\"volt_cpp_variant_out({}{})\"{}", S(extra), S(cpp), copy holes, S(tail));
            call.append(ptrs.as_str());
            call.append(");");
            this.line(call.as_str());
            val cases = case_names(&r.elems);
            for (j) in 0..r.elems.len {
                val js = unum(@cast<u64>(j));
                if (j + 1 < r.elems.len) {
                    this.line(fmt("if (try_i == {}) {{", copy js).as_str());
                    this.line(fmt3("    return {}::{}(try_{});", copy r.vty, copy *cases.at(j), copy js).as_str());
                    this.line("}");
                } else {
                    this.line(fmt3("return {}::{}(try_{});", copy r.vty, copy *cases.at(j), copy js).as_str());
                }
            }
        },
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
            this.line(fmt4("val try_got = @cpp<str{}>(\"{}({})\"{});", S(extra), conv_or(r, "volt_cpp_dup"), S(cpp), S(tail)).as_str());
            this.text_out("try_got");
        },
        .VECTOR => {
            var got = fmt4("val try_got = @cpp<{}[..]{}>(\"{}({})\"", copy r.elem, S(extra), conv_or(r, "volt_cpp_dup_vec"), S(cpp));
            got.append(tail);
            got.append(");");
            this.line(got.as_str());
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

// the lines returning a handle of the object at (a C++ expression), or none for a null one
attach fn handle_or_none(this: cpp_gen&, at: str, borrowed: bool, extra: str, tail: str) -> void {
    this.line(fmt3("val try_p = @cpp<void*{}>(\"{}\"{});", S(extra), S(at), S(tail)).as_str());
    this.line("if (try_p == null) {");
    this.line("    return null;");
    this.line("}");
    if (borrowed) {
        this.line("return { cpp: try_p, borrowed: true };");
    } else {
        this.line("return { cpp: try_p };");
    }
}

// the C++ helper turning a result into what @cpp returns: a form's own, or the way's
fn conv_or(r: cpp_ret&, way: str) -> std::string {
    if (r.conv.len() > 0) {
        return copy r.conv;
    }
    return S(way);
}

// the lines turning text the wrapper copied out (str r, malloc'd) into a std::string, and returning
// it (the generated locals start with try_, so a C++ parameter of an ordinary name can't clash)
attach fn text_out(this: cpp_gen&, r: str) -> void {
    this.line(fmt("var try_text = std::string::from({});", S(r)).as_str());
    this.line(fmt("@cpp<void>(\"std::free((void *){0}.ptr)\", {});", S(r)).as_str());
    this.line("return try_text;");
}

// the try_ form of a call: the plain form called in catch mode (volt_cpp_catch_begin), returning
// a cpp_error naming what it threw (last_exception() says what it said); its value, made of zeroes
// then, is dropped
attach fn try_text(this: cpp_gen&, generics: str, head: str, params: str, r: cpp_ret&, args: str) -> void {
    // `attach fn area(this: Shape&` gives `attach fn try_area(this: Shape&`, calling this.area(...)
    var at: usize = 0;
    if (starts_with(head, "attach fn ")) {
        at = 10;
    } else if (starts_with(head, "fn ")) {
        at = 3;
    }
    val rest = head[at..head.len];
    var paren: usize = 0;
    while (paren < rest.len && rest[paren] != '(') {
        paren += 1;
    }
    val name = rest[0..paren];
    var after = "";
    if (paren < rest.len) {
        after = rest[paren + 1..rest.len];
    }
    var callee = S(name);
    if (starts_with(after, "this:")) {
        callee = fmt("this.{}", S(name));
    } else if (starts_with(after, "static this: ")) {
        // the type, to a comma outside its generic arguments (Pair<A, B>)
        val t = after[13..after.len];
        var e: usize = 0;
        var depth = 0;
        while (e < t.len && !(t[e] == ',' && depth == 0)) {
            if (t[e] == '<') {
                depth += 1;
            } else if (t[e] == '>') {
                depth -= 1;
            }
            e += 1;
        }
        callee = fmt2("{}::{}", S(t[0..e]), S(name));
    }
    // generic arguments the call's own can't tell
    val gs = generic_names(generics);
    var explicit: std::string = {};
    for (g&) in gs.items() {
        if (!mentions(params, g.as_str()) && !mentions(rest, g.as_str())) {
            if (explicit.len() > 0) {
                explicit.append(", ");
            }
            explicit.append(g.as_str());
        }
    }
    if (explicit.len() > 0) {
        callee = fmt2("{}<{}>", move callee, move explicit);
    }
    if (generics.len > 0) {
        this.line(generics);
    }
    this.tries = true;
    // (the result in parentheses: cpp_error!T? is an optional error union, cpp_error!T[3] an array)
    var rv = copy r.vty;
    if (!starts_with(rv.as_str(), "(")) {
        rv = fmt("({})", move rv);
    }
    // try_as, not try_as_: the keyword's underscore isn't needed once it's prefixed
    var tname = S(rest);
    if (paren > 1 && rest[paren - 1] == '_' && is_keyword(rest[0..paren - 1])) {
        tname = fmt2("{}{}", S(rest[0..paren - 1]), S(rest[paren..rest.len]));
    }
    this.line(fmt4("{}try_{}{}) -> cpp_error!{} {{", S(head[0..at]), move tname, S(params), move rv).as_str());
    this.depth += 1;
    this.line(fmt("val try_m = @cpp<void*>(\"volt_cpp_catch_begin({})\");", copy this.kinds).as_str());
    val void_ = r.vty.as_str() == "void";
    if (void_) {
        this.line(fmt2("{}({});", copy callee, S(args)).as_str());
    } else {
        this.line(fmt3("val try_r: {} = {}({});", copy r.vty, copy callee, S(args)).as_str());
    }
    this.line("val try_k = @cpp<i32>(\"volt_cpp_catch_end({0})\", try_m);");
    this.line("if (try_k != 0) {");
    this.line("    return volt_cpp_error_of(try_k);");
    this.line("}");
    if (void_) {
        this.line("return;");
    } else {
        this.line("return try_r;");
    }
    this.depth -= 1;
    this.line("}");
}

// the names a generic list declares (`<T: type, N: usize>`: T, N)
fn generic_names(generics: str) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    var i: usize = 0;
    var start = true;
    while (i < generics.len) {
        val ch = generics[i];
        if (start && ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_')) {
            var e = i;
            while (e < generics.len && generics[e] != ':' && generics[e] != ',' && generics[e] != '>') {
                e += 1;
            }
            put(&out, S(generics[i..e]));
            i = e;
            start = false;
            continue;
        }
        if (ch == '<' || ch == ',') {
            start = true;
        }
        i += 1;
    }
    return out;
}

// does text name word (as a whole identifier)?
fn mentions(text: str, word: str) -> bool {
    if (word.len == 0 || text.len < word.len) {
        return false;
    }
    for (i) in 0..text.len - word.len + 1 {
        if (text[i..i + word.len] == word) {
            val before_ok = i == 0 || !ident_char(text[i - 1]);
            val after_ok = i + word.len == text.len || !ident_char(text[i + word.len]);
            if (before_ok && after_ok) {
                return true;
            }
        }
    }
    return false;
}

fn ident_char(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
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
    // a public bit-field isn't one of its Volt fields (they're whole bytes): f() and set_f(v)
    for (f&) in children(c).items() {
        if (clang::clang_getCursorKind(*f) == clang::CXCursor_FieldDecl && is_public(*f) && clang::clang_Cursor_isBitField(*f) != 0) {
            this.field_accessors(*f, self_ty.as_str(), fmt("{0}.{}", cursor_name(*f)).as_str(), "this", gen.as_str(), extra.as_str());
        }
    }
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
    if (tr.polymorphic && !tr.final_) {
        maps = this.virt_maps(c, q, &vs);
    }
    this.line(fmt("// C++'s {}: it isn't trivially copyable, so Volt holds it by handle (C++ allocates it)", S(q)).as_str());
    if (maps) {
        this.line(fmt2("@attributes([@attach_as(\"{}_virtuals\"), @cpp_handle(\"{}\")])", S(vn), S(q)).as_str());
    } else {
        this.line(fmt("@attributes([@cpp_handle(\"{}\")])", S(q)).as_str());
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
    // (an object derive made is deleted and copied as what it is: the Volt side too)
    this.line(fmt("attach fn delete(this: {}&) -> void {{", S(vn)).as_str());
    this.line("    if (this.cpp != null && !this.borrowed) {");
    if (maps) {
        this.line(fmt("        @cpp<void>(\"volt_dir_delete< ::{}>({{0}}, {{1}})\", this.cpp, this.volt);", S(q)).as_str());
    } else {
        this.line(fmt("        @cpp<void>(\"delete ({} *){{0}}\", this.cpp);", S(q)).as_str());
    }
    this.line("    }");
    this.line("}");
    if (tr.copyable || (maps != null && tr.base_copy)) {
        this.line(fmt2("attach fn copy(this: {}&) -> {} {{", S(vn), S(vn)).as_str());
        this.line("    if (this.cpp == null) {");
        this.line("        return { cpp: null };");
        this.line("    }");
        if (maps) {
            this.line("    var v: void* = null;");
            this.line(fmt2("    val p = @cpp<void*>(\"volt_dir_copy< ::{}, {}>({{0}}, {{1}}, (void **){{2}})\", this.cpp, this.volt, @cast<void*>(&v));", S(q), S(cpp_bool(tr.copyable))).as_str());
            this.line("    return { cpp: p, volt: v };");
        } else {
            this.line(fmt2("    return {{ cpp: @cpp<void*>(\"new {}(*({} *){{0}})\", this.cpp) }};", S(q), S(q)).as_str());
        }
        this.line("}");
    }
    // the methods before the fields' getters and set_ methods, so a method of the same signature
    // (a set_x of its own) is the one Volt calls
    this.class_methods(c, vn, q, obj.as_str());
    for (f&) in children(c).items() {
        if (clang::clang_getCursorKind(*f) == clang::CXCursor_FieldDecl && is_public(*f)) {
            this.field_accessors(*f, vn, fmt2("{}.{}", copy obj, cursor_name(*f)).as_str(), "this.cpp", "", "");
        }
    }
    this.casts(c, vn, q);
    // the object's type, as C++ names it (its dynamic type, for a class with virtual methods)
    if (this.first_time(fmt("attach fn cpp_type_name(this: {}&", S(vn)).as_str(), "")) {
        val r: cpp_ret = { vty: S("std::string"), way: ret_way::STRING };
        if (maps) {
            this.fn_text("", fmt("attach fn cpp_type_name(this: {}&) -> std::string", S(vn)).as_str(), &r, fmt("volt_dir_name< ::{}>({{0}}, {{1}})", S(q)).as_str(), ", this.cpp, this.volt", "");
        } else {
            this.fn_text("", fmt("attach fn cpp_type_name(this: {}&) -> std::string", S(vn)).as_str(), &r, fmt("volt_cpp_type_name({})", copy obj).as_str(), ", this.cpp", "");
        }
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
    via: std::string = {};   // the bases it's reached through, as an as_ name's start (B1_)
    chain: std::vec<std::string> = {}; // ...as C++ names, outermost first
}

fn all_bases(c: clang::CXCursor, public_: bool, out: std::vec<base_path>&, depth: u32) -> void {
    val none: std::vec<std::string> = {};
    bases_via(c, public_, out, depth, "", &none);
}

fn bases_via(c: clang::CXCursor, public_: bool, out: std::vec<base_path>&, depth: u32, via: str, chain: std::vec<std::string>&) -> void {
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
        put(out, { c: b, public_: pub, virtual_: clang::clang_isVirtualBase(*ch) != 0, via: S(via), chain: copy *chain });
        var next = copy *chain;
        put(&next, cpp_qual(b));
        bases_via(b, pub, out, depth + 1, fmt2("{}{}_", S(via), vname(cursor_name(b).as_str())).as_str(), &next);
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
        val bp = copy *bases.at(i);
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
        val bn = vname(cursor_name(bp.c).as_str());
        if (plain + virt_ > 1) {
            // that base more than once, each its own object: as_ names the path (as_B1_A), the
            // virtual one (one object however many paths) by its first
            var vdone = false;
            for (j) in 0..bases.len {
                val pj = bases.at(j);
                if (!pj->public_ || cpp_qual(pj->c).as_str() != bq.as_str() || (pj->virtual_ && vdone)) {
                    continue;
                }
                vdone = vdone || pj->virtual_;
                val pn = fmt2("{}{}", copy pj->via, copy bn);
                if (!this.first_time(fmt2("attach fn as_{}(this: {}&", copy pn, S(vn)).as_str(), "")) {
                    continue;
                }
                var obj = fmt("&volt_cpp_obj< ::{}>({{0}})", S(q));
                for (k&) in pj->chain.items() {
                    obj = fmt2("static_cast< ::{} *>({})", copy *k, move obj);
                }
                obj = fmt2("static_cast< ::{} *>({})", copy bq, move obj);
                if (btr->trivial) {
                    this.line(fmt3("attach fn as_{}(this: {}&) -> {}& {{", copy pn, S(vn), copy bvt).as_str());
                    this.line(fmt2("    return @cpp<{}&>(\"*{}\", this.cpp);", copy bvt, move obj).as_str());
                } else {
                    this.line(fmt3("attach fn as_{}(this: {}&) -> {} {{", copy pn, S(vn), copy bvt).as_str());
                    this.line(fmt("    return {{ cpp: @cpp<void*>(\"{}\", this.cpp), borrowed: true }};", move obj).as_str());
                }
                this.line("}");
            }
            continue;
        }
        if (!this.first_time(fmt2("attach fn as_{}(this: {}&", copy bn, S(vn)).as_str(), "")) {
            this.line(fmt3("// (no {}::as_{} for {}: the name is taken)", S(q), copy bn, copy bq).as_str());
            continue;
        }
        if (btr->trivial) {
            this.line(fmt3("attach fn as_{}(this: {}&) -> {}& {{", copy bn, S(vn), copy bvt).as_str());
            this.line(fmt4("    return @cpp<{}&>(\"static_cast< ::{} &>(volt_cpp_obj< ::{}>({{0}}))\", this.cpp);", copy bvt, copy bq, S(q), S("")).as_str());
            this.line("}");
            continue;
        }
        this.line(fmt3("attach fn as_{}(this: {}&) -> {} {{", copy bn, S(vn), copy bvt).as_str());
        this.line(fmt3("    return {{ cpp: @cpp<void*>(\"static_cast< ::{} *>(&volt_cpp_obj< ::{}>({{0}}))\", this.cpp), borrowed: true }};", copy bq, S(q), S("")).as_str());
        this.line("}");
        if (btr->polymorphic && this.first_time(fmt2("attach fn as_{}(this: {}&", vname(cursor_name(c).as_str()), copy bvt).as_str(), "")) {
            this.line(fmt3("attach fn as_{}(this: {}&) -> {}? {{", vname(cursor_name(c).as_str()), copy bvt, S(vn)).as_str());
            this.line(fmt2("    val p = @cpp<void*>(\"volt_cpp_down< ::{}>(&volt_cpp_obj< ::{}>({{0}}))\", this.cpp);", S(q), copy bq).as_str());
            this.line("    if (p == null) {");
            this.line("        return null;");
            this.line("    }");
            this.line(fmt("    val h: {} = {{ cpp: p, borrowed: true }};", S(vn)).as_str());
            this.line("    return h;");
            this.line("}");
        }
    }
}

// a field's getter (of the same name) and set_ method (a bit-field's too: C++ does the bit work);
// at: the field, in a C++ expression ({0}: the object), self what the Volt method passes for it
// (this.cpp for a handle, this for a class held by value), gen and extra a class template's generics
attach fn field_accessors(this: cpp_gen&, f: clang::CXCursor, vn: str, at: str, self: str, gen: str, extra: str) -> void {
    val none: std::vec<str> = {};
    val ft = clang::clang_getCursorType(f);
    // (an unnamed bit-field is padding)
    if (ft.kind == clang::CXType_LValueReference || ft.kind == clang::CXType_RValueReference || cursor_name(f).len() == 0) {
        return;
    }
    val fv = vname(cursor_name(f).as_str());
    var r = this.result(ft, &none) ?? return;
    // the getter gives a copy of it
    if (this.copies_out(ft) && this.first_time(fmt2("attach fn {}(this: {}&", copy fv, S(vn)).as_str(), "")) {
        this.fn_text(gen, fmt3("attach fn {}(this: {}&) -> {}", copy fv, S(vn), copy r.vty).as_str(), &r, at, fmt(", {}", S(self)).as_str(), extra);
    }
    // a std::function: set_ takes the closure itself, which the field keeps (closure_setter)
    val st = std_template(ft) ?? S("");
    if (st.as_str() == "function" && clang::clang_isConstQualifiedType(ft) == 0) {
        this.closure_setter(ft, fv.as_str(), vn, at, self, gen, extra);
        return;
    }
    if (!this.assignable(ft)) {
        return;
    }
    val a = this.param(ft, "v", 1, &none) ?? return;
    if (this.first_time(fmt2("attach fn set_{}(this: {}&", copy fv, S(vn)).as_str(), fmt(",{}", copy a.vty).as_str())) {
        if (gen.len > 0) {
            this.line(gen);
        }
        this.line(fmt3("attach fn set_{}(this: {}&, v: {}) -> void {{", copy fv, S(vn), copy a.vty).as_str());
        this.line(fmt5("    @cpp<void{}>(\"{} = {}\", {}, {});", S(extra), S(at), copy a.cpp, S(self), copy a.pass).as_str());
        this.line("}");
    }
}

// set_f of a std::function field: the closure itself, moved in (generic over its type) and boxed;
// C++ gets a std::function owning the box, which a Volt fn deletes when the last copy of it goes
// (volt_cpp_closure_drop<C>, passed by its symbol)
attach fn closure_setter(this: cpp_gen&, ft: clang::CXType, fv: str, vn: str, at: str, self: str, gen: str, extra: str) -> void {
    val sig = this.fn_sig(ft) ?? return;
    if (!this.first_time(fmt2("attach fn set_{}(this: {}&", S(fv), S(vn)).as_str(), ",closure")) {
        return;
    }
    // the closure's type joins the class template's generics
    var g = S("<C: type>");
    if (gen.len > 0) {
        g = fmt("{}, C: type>", S(gen[0..gen.len - 1]));
    }
    this.closures = true;
    this.line(g.as_str());
    this.line(fmt2("attach fn set_{}(this: {}&, f: C) -> void {{", S(fv), S(vn)).as_str());
    // the field keeps it: one holding references (|x&|) would outlive what they point at
    this.line("    comptime if (@typeinfo(C).borrows) {");
    this.line("        @compile_error(\"a std::function field keeps its closure, so it can't capture by reference (|x&|): capture by value or move\");");
    this.line("    }");
    // the fn value's function is the closure's; its env becomes the box (volt_cpp_owned_fn)
    this.line("    var c = move f;");
    this.line(fmt("    val fv: {} = c;", copy sig.vty).as_str());
    this.line("    val a: std::mem::default_allocator = {};");
    this.line("    val p: C* = a.malloc<C>() catch @panic(\"out of memory\");");
    this.line("    @write(p, move c);");
    // ({&0} first: @cpp's arguments for it come before the object's)
    this.line(fmt4("    @cpp<void{}>(\"{} = volt_cpp_owned_fn<{}>({{2}}, {{3}}, {{&0}})\", volt_cpp_closure_drop<C>, {}, @cast<void*>(&fv), @cast<void*>(p));", S(extra), replace_all(at, "{0}", "{1}"), copy sig.cpp, S(self)).as_str());
    this.line("}");
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
            // held by handle instead, as a generic struct (its parameters all types, the defaulted
            // rest C++'s); std's smart pointers and std::function keep their own forms
            val c = *(this.cursors.get(*q) ?? continue);
            val tps = template_params(c);
            val path = *(this.templates.get(*q) ?? continue);
            val vn = last_part(path, "");
            val special = vn.as_str() == "unique_ptr" || vn.as_str() == "shared_ptr" || vn.as_str() == "function";
            if (tps) {
                if (tps.len > 0 && !special) {
                    this.tmpl_handles.put(*q, path);
                }
            }
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
            if (slash == null) {
                put(&this.std_stems, S(name));
            }
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
//     static const bool t0 = __is_trivially_copyable(::geo::Shape); (d0, c0, a0, n0, p0, f0, v0, e0, m0 likewise)
// (static const, not constexpr: a header read under C++98 is probed the same way)
// A class it can't answer for is held by handle, and Volt neither makes, copies nor assigns one.
// ponytail: the second parse reads every header again (<string>, <vector>: about twice the
// import's time); a precompiled preamble with clang_reparseTranslationUnit if that ever matters
attach fn probe(this: cpp_gen&, src: str, args: std::vec<str>&) -> void {
    var names: std::vec<str> = {};
    var text = S(src);
    // clang's builtins, which every standard has (C++98's library has no <type_traits>)
    text.append("#include <exception>\nnamespace volt_probe {\n");
    for (e) in this.classes.iter() {
        val i = unum(@cast<u64>(names.len));
        val q = S(*e.key);
        text.append(fmt2("static const bool t{} = __is_trivially_copyable(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("static const bool d{} = __is_destructible(::{});\n", copy i, copy q).as_str());
        text.append(fmt3("static const bool c{} = __is_constructible(::{}, const ::{} &);\n", copy i, copy q, copy q).as_str());
        text.append(fmt3("static const bool a{} = __is_assignable(::{} &, ::{} &&);\n", copy i, copy q, copy q).as_str());
        text.append(fmt2("static const bool n{} = __is_constructible(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("static const bool p{} = __is_polymorphic(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("static const bool f{} = __is_final(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("static const bool v{} = __has_virtual_destructor(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("static const bool e{} = __is_convertible_to(::{} *, const std::exception *);\n", copy i, copy q).as_str());
        text.append(fmt3("static const bool m{} = __is_constructible(::{}, ::{} &&);\n", copy i, copy q, copy q).as_str());
        put(&names, *e.key);
        this.traits.put(*e.key, {});
    }
    text.append("}\n");
    if (names.len == 0) {
        return;
    }
    // each class's copy, made for those clang says can be copied (copy_check)
    val first = copies_text(&text, &names, true);
    var pargs = copy *args;
    put(&pargs, "-ferror-limit=0");
    var tu = clang_parse("volt_cpp_probe.cpp", text.as_str(), &pargs);
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
    var cands: std::vec<str> = {};
    var subs: std::vec<str> = {};
    for (n&) in names.items() {
        val tr = this.traits.get(*n) ?? continue;
        if (tr->copyable && !tr->trivial) {
            put(&cands, *n);
        }
        if (tr->polymorphic && !tr->final_) {
            tr->base_copy = true;
            put(&subs, *n);
        }
    }
    val lines = tu.error_lines("volt_cpp_probe.cpp");
    this.copy_failures(&cands, &lines, first, &names, false);
    if (cands.len > 0 || subs.len > 0) {
        this.copy_check(src, &pargs, cands, subs);
    }
}

// the copy of each class in names, a function on a line of its own (the first's line returned);
// guarded: only one clang says can be copied, and isn't trivially, is copied
fn copies_text(text: std::string&, names: std::vec<str>&, guarded: bool) -> u32 {
    text.append("\nnamespace volt_copies {\ntemplate <bool B> struct copy_if { template <class T> static void run(const T &) {} };\ntemplate <> struct copy_if<true> { template <class T> static void run(const T &a) { T b(a); (void)b; } };\n");
    var first: u32 = 1;
    for (ch) in text.as_str() {
        if (ch == '\n') {
            first += 1;
        }
    }
    for (i) in 0..names.len {
        val q = S(*names.at(i));
        var cond = S("true");
        if (guarded) {
            cond = fmt3("__is_constructible(::{}, const ::{} &) && !__is_trivially_copyable(::{})", copy q, copy q, copy q);
        }
        text.append(fmt3("inline void c{}(const ::{} &a) {{ copy_if<{}>::run(a); }}\n", unum(@cast<u64>(i)), copy q, copy cond).as_str());
    }
    text.append("}\n");
    return first;
}

// the copy each class in subs gets as a subclass's base (the subclass derive makes copies with its
// copy constructor, which may be protected; an abstract class's too), an explicit instantiation on a
// line of its own (the first's line returned)
fn sub_copies_text(text: std::string&, subs: std::vec<str>&) -> u32 {
    text.append("\nnamespace volt_copies {\ntemplate <class T> struct sub : T {\n    sub(const T &a);\n};\ntemplate <class T> sub<T>::sub(const T &a) : T(a) {}\n}\n");
    var first: u32 = 1;
    for (ch) in text.as_str() {
        if (ch == '\n') {
            first += 1;
        }
    }
    for (q&) in subs.items() {
        text.append(fmt("template struct volt_copies::sub< ::{}>;\n", S(*q)).as_str());
    }
    return first;
}

// the candidates (cands) whose copy (at line first + its index in names) clang failed on: not
// copyable after all (sub: not by a subclass), and out of cands. Whether any were
attach fn copy_failures(this: cpp_gen&, cands: std::vec<str>&, lines: std::vec<u32>&, first: u32, names: std::vec<str>&, sub: bool) -> bool {
    var keep: std::vec<str> = {};
    var any = false;
    for (c&) in cands.items() {
        var at: u32? = null;
        for (i) in 0..names.len {
            if (*names.at(i) == *c) {
                at = first + @cast<u32>(i);
            }
        }
        var failed = false;
        for (l) in lines.items() {
            failed = failed || (at ?? 0) == l;
        }
        if (failed) {
            val tr = this.traits.get(*c) ?? continue;
            if (sub) {
                tr->base_copy = false;
            } else {
                tr->copyable = false;
            }
            any = true;
        } else {
            put(&keep, *c);
        }
    }
    *cands = move keep;
    return any;
}

// a class clang says can be copied whose copy doesn't compile (one with a
// std::vector<std::unique_ptr<T>> field: the vector's copy constructor is declared, unconstrained)
// can't be: each one's copy is made in a function on a line of its own (copies_text), and an error
// there (or in what it instantiates) says which. A failing instantiation is reported once, so when
// the probe's found some it asks again of the rest until none fails
attach fn copy_check(this: cpp_gen&, src: str, args: std::vec<str>&, cands0: std::vec<str>, subs0: std::vec<str>) -> void {
    var cands = move cands0;
    var subs = move subs0;
    val main = "volt_cpp_copies.cpp";
    var tu: clang_tu = { index: null, tu: null };
    var round: u32 = 0;
    while ((cands.len > 0 || subs.len > 0) && round < 8) {
        round += 1;
        var text = S(src);
        val names = copy cands;
        val first = copies_text(&text, &names, false);
        val snames = copy subs;
        val sfirst = sub_copies_text(&text, &snames);
        if (tu.tu == null || !tu.reparse(main, text.as_str())) {
            tu = clang_parse_opts(main, text.as_str(), args, 260);
        }
        val lines = tu.error_lines(main);
        val a = this.copy_failures(&cands, &lines, first, &names, false);
        val b = this.copy_failures(&subs, &lines, sfirst, &snames, true);
        if (!a && !b) {
            return;
        }
    }
    // still failing after as many rounds: what's left isn't copied (not copying is safe; a copy
    // that doesn't compile breaks the whole import)
    for (c&) in cands.items() {
        val tr = this.traits.get(*c) ?? continue;
        tr->copyable = false;
    }
    for (c&) in subs.items() {
        val tr = this.traits.get(*c) ?? continue;
        tr->base_copy = false;
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
    out: u8 = 0;            // 1: a class Volt holds by value, written to *out; 2: a std::string, assigned to *out;
                            // 3: anything else, made in *out (write)
    cast: std::string = {}; // the C++ type it's cast back to (an enum from its tag)
    write: std::string = {}; // 3: the C++ making it in *out ({0}) from the Volt value ({1})
    pass: std::string = {};  // 3: what the thunk passes for the Volt value (r)
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
    // through typedefs (using Ref = T&); a T&& is read as a const T& is (the override can't take
    // the object over, as a C++ one could)
    val ck = clang::clang_getCanonicalType(t).kind;
    val is_ref = ck == clang::CXType_LValueReference || ck == clang::CXType_RValueReference;
    var base = t;
    if (is_ref) {
        base = pointee(t);
    }
    val mut_ref = ck == clang::CXType_LValueReference && clang::clang_isConstQualifiedType(base) == 0;
    if (!mut_ref && (char_text(base, "basic_string") || char_text(base, "basic_string_view"))) {
        return { vty: S("str"), thunk: S("str"), cpp_ty: S("volt_str"), cpp: fmt("volt_cpp_view({})", copy a), arg: copy a };
    }
    val hc = this.handle_of(base);
    if (hc) {
        val vt = this.vtype(base, &none) ?? return null;
        return { vty: fmt("{}&", copy vt), thunk: S("void*"), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: fmt("&h{}", unum(@cast<u64>(i))), handle: copy vt };
    }
    if (is_class(base) && this.traits.get(cpp_qual(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(base))).as_str()) != null) {
        // an imported class held by value
        val vt = this.vtype(base, &none) ?? return null;
        if (is_ref) {
            return { vty: fmt("{}&", copy vt), thunk: fmt("{}&", copy vt), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: copy a };
        }
        return { vty: copy vt, thunk: fmt("{}&", copy vt), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: fmt("*{}", copy a) };
    }
    if (mut_ref && !is_class(base)) {
        // a number (or bool, enum, pointer) the override may change: a reference to C++'s
        val vt = this.vtype(base, &none) ?? return null;
        return { vty: fmt("{}&", copy vt), thunk: fmt("{}&", copy vt), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: copy a };
    }
    if (is_class(base) || is_ref) {
        // any other: by its address, read into its Volt form as a result of that type would be (a
        // copy: a std::function's callable, a form)
        if (mut_ref) {
            return null;
        }
        val r = this.result(clang::clang_getUnqualifiedType(clang::clang_getCanonicalType(base)), &none) ?? return null;
        val rd = this.virt_reader(base, &r);
        return { vty: copy r.vty, thunk: S("void*"), cpp_ty: S("void *"), cpp: fmt("(void *)&{}", copy a), arg: fmt2("{}({})", move rd, copy a) };
    }
    val vt = this.vtype(t, &none) ?? return null;
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_Enum) {
        val under = fmt("std::underlying_type_t<{}>", canon(t));
        return { vty: copy vt, thunk: copy vt, cpp_ty: copy under, cpp: fmt2("({}){}", copy under, copy a), arg: copy a };
    }
    return { vty: copy vt, thunk: copy vt, cpp_ty: canon(t), cpp: copy a, arg: copy a };
}

// the Volt fn reading an override's argument of type t (by its address) into its Volt form r, written
// with the instances once a type
attach fn virt_reader(this: cpp_gen&, t: clang::CXType, r: cpp_ret&) -> std::string {
    val cpp = S(strip_const(canon(t).as_str()));
    val have = this.readers.get(cpp.as_str());
    if (have) {
        return S(*have);
    }
    val name = fmt("volt_read_{}", unum(@cast<u64>(this.inst_count)));
    this.inst_count += 1;
    this.readers.put(this.c.intern(copy cpp), this.c.intern(copy name));
    var saved = copy this.out;
    val depth = this.depth;
    this.out = {};
    this.depth = 0;
    this.fn_text("", fmt2("fn {}(p: void*) -> {}", copy name, copy r.vty).as_str(), r, fmt("(*({} *){{0}})", copy cpp).as_str(), ", p", "");
    put(&this.pending, copy this.out);
    this.out = move saved;
    this.depth = depth;
    return name;
}

// a virtual method's result, from Volt back to C++: numbers, enums and pointers as they are, a class
// Volt holds by value and a std::string through a pointer to C++'s, anything else made in C++'s
// storage from its Volt form (as a parameter of its type is)
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
    if (is_class(t) && this.handle_of(t) == null && this.traits.get(cpp_qual(clang::clang_getTypeDeclaration(ct)).as_str()) != null) {
        return { vty: this.vtype(t, &none) ?? return null, cpp_ty: S("void"), out: 1 };
    }
    if (is_class(t)) {
        val a = this.param(t, "r", 1, &none) ?? return null;
        return { vty: copy a.vty, cpp_ty: S("void"), out: 3, write: fmt2("new ((void *){{0}}) {}({})", canon(t), copy a.cpp), pass: copy a.pass };
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
    var dn = dir_name(q);
    val bn = fmt("{}_base", copy dn);
    val copyable = (this.traits.get(q) ?? return).base_copy;
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
    this.line("    ops: void*; // its C++ subclass's volt_dir_ops (C++ sets it, making the object)");
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
        } else if (m.ret.out == 3) {
            this.line(fmt2("val r: {} = {};", copy m.ret.vty, move call).as_str());
            this.line(fmt2("@cpp<void>(\"{}\", out, {});", copy m.ret.write, copy m.ret.pass).as_str());
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
    this.line("// a copy of the Volt side (the C++ subclass's copy copies the rest), or null when T has none");
    this.line("<T: type>");
    this.line(fmt("fn {}_volt_copy(d: void*) -> void* {{", S(vn)).as_str());
    this.line("    comptime if (@typeinfo(T).is_pod || @has_method(T, \"copy\")) {");
    this.line(fmt("        val b = @cast<{}_volt<T>*>(d);", S(vn)).as_str());
    this.line(fmt("        val p = @cpp<void*>(\"std::malloc({{0}})\", @sizeof({}_volt<T>));", S(vn)).as_str());
    this.line("        if (p == null) {");
    this.line("            @panic(\"out of memory\");");
    this.line("        }");
    this.line(fmt("        @write(@cast<{}_volt<T>*>(p), {{ ops: b->ops, tid: b->tid, impl: copy b->impl }});", S(vn)).as_str());
    this.line("        return p;");
    this.line("    } else {");
    this.line("        return null;");
    this.line("    }");
    this.line("}");
    this.line("// the Volt type's name (cpp_type_name of a derived object)");
    this.line("<T: type>");
    this.line(fmt("fn {}_volt_name() -> str {{", S(vn)).as_str());
    this.line("    return @typeinfo(T).canonical_name;");
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
    this.line(fmt("@write(@cast<{}_volt<T>*>(p), {{ ops: null, tid: @typeid(T), impl: move impl }});", S(vn)).as_str());
    this.line("return p;");
    this.depth -= 1;
    this.line("}");
    // T::derive(impl, the constructor's arguments), one each constructor (public or protected): the
    // subclass's template arguments are the drop function, then each method's thunk and whether T
    // has it
    var lead = fmt3("volt_d, {}_volt_drop<T>, {}_volt_copy<T>, {}_volt_name<T>", S(vn), S(vn), S(vn));
    var targs = S("{&1}, {&2}, {&3}");
    for (k) in 0..maps.len {
        val m = maps.at(k);
        lead.append(fmt3(", {}_volt_{}<T>, @has_method(T, \"{}\", ", S(vn), copy m.vname, copy m.vname).as_str());
        lead.append(fmt("{}&)", S(vn)).as_str());
        targs.append(fmt2(", {{&{}}}, {{={}}}", unum(@cast<u64>(4 + 2 * k)), unum(@cast<u64>(5 + 2 * k))).as_str());
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
    val obj = fmt("volt_cpp_obj< ::{}>({{0}})", S(q));
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
            this.field_accessors(*ch, vn, fmt3("({}.*{}::volt_pf_{}())", copy obj, copy bn, copy mn).as_str(), "this.cpp", "", "");
            cpp.append(fmt2("    static auto volt_pf_{}() {{ return &{}::", copy mn, copy bn).as_str());
            cpp.append(fmt("{}; }\n", copy mn).as_str());
        }
    }
    // the C++ subclasses: what each has (the Volt side, the way to the protected members), then one
    // per Volt type
    var text = fmt("// Volt's subclasses of {} (derive): what every one has, the Volt side and the protected\n// members\n", S(q));
    text.append(fmt2("struct {} : ::{} {{\n", copy bn, S(q)).as_str());
    text.append("    void *volt_d; // the Volt side: its subclass's ops, the Volt value and its type's id\n");
    text.append("    static inline char volt_tag = 0; // (its subclasses' ops have it)\n");
    text.append(fmt3("    template <class... A>\n    explicit {}(void *d, A &&...a) : ::{}(std::forward<A>(a)...), volt_d(d) {{ volt_dir_put(volt_self(), *(const volt_dir_ops *const *)d); }}\n", copy bn, S(q), S("")).as_str());
    text.append(fmt("    virtual ~{}() {{ volt_dir_put(volt_self(), 0); }}\n", copy bn).as_str());
    text.append(fmt("    void *volt_self() const {{ return (void *)static_cast<const ::{} *>(this); }}\n", S(q)).as_str());
    text.append(cpp.as_str());
    text.append("};\n\n");
    text.append("// one per Volt type: FD deletes the Volt side, FC copies it and FN names its type, Fk is method\n// k's thunk and Ok whether the type has it (else the method is C++'s own)\n");
    text.append("template <auto FD, auto FC, auto FN");
    for (k) in 0..maps.len {
        text.append(fmt2(", auto F{}, bool O{}", unum(@cast<u64>(k)), unum(@cast<u64>(k))).as_str());
    }
    text.append(">\n");
    text.append(fmt2("struct {} final : {} {{\n", copy dn, copy bn).as_str());
    text.append(fmt2("    using {}::{};\n", copy bn, copy bn).as_str());
    text.append(fmt2("    struct volt_make {{\n        void *d;\n        template <class... A>\n        {} operator()(A &&...a) const {{\n            *(const volt_dir_ops **)d = &volt_ops;\n            return {}(d, std::forward<A>(a)...);\n        }}\n    }};\n", copy dn, copy dn).as_str());
    text.append("    static volt_make make(void *d) { return {d}; }\n");
    text.append(fmt("    ~{}() override {{ ((void (*)(void *))FD)(volt_d); }}\n", copy dn).as_str());
    // (the object as what it is: volt_dir_ops)
    if (copyable) {
        text.append(fmt("    static void *volt_copy(void *o, void **out) {{\n        const {} *self = static_cast<const ", copy dn).as_str());
        text.append(fmt3("{} *>((::{} *)o);\n        void *d = ((void *(*)(void *))FC)(self->volt_d);\n        if (!d) {{\n            return 0;\n        }}\n        *out = d;\n        return (void *)static_cast< ::{} *>(", copy dn, S(q), S(q)).as_str());
        text.append(fmt2("new {}(d, static_cast<const ::{} &>(*self)));\n    }}\n", copy dn, S(q)).as_str());
    } else {
        text.append("    static void *volt_copy(void *, void **) { return 0; }\n");
    }
    text.append(fmt2("    static void volt_delete(void *o) {{ delete static_cast<{} *>((::{} *)o); }}\n", copy dn, S(q)).as_str());
    text.append("    static std::string volt_name(void *) {\n        volt_str n = ((volt_str (*)())FN)();\n        return std::string((const char *)n.ptr, n.len);\n    }\n");
    text.append(fmt("    static inline const volt_dir_ops volt_ops = {{&volt_copy, &volt_delete, &volt_name, &{}::volt_tag}};\n", copy bn).as_str());
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
            text.append(fmt3("            alignas({}) unsigned char volt_r[sizeof({})];\n            volt_cpp_enter([&]() {{ {}(", copy rt, copy rt, copy f).as_str());
            text.append(fmt("{}, volt_r); }});\n", copy pass).as_str());
            text.append(fmt("            return *std::launder(reinterpret_cast<{} *>(volt_r));\n", copy rt).as_str());
        } else if (m.ret.out == 2) {
            text.append(fmt2("            std::string volt_r;\n            volt_cpp_enter([&]() {{ {}({}, &volt_r); }});\n            return volt_r;\n", copy f, copy pass).as_str());
        } else if (m.ret.out == 3) {
            text.append(fmt3("            alignas({}) unsigned char volt_r[sizeof({})];\n            volt_cpp_enter([&]() {{ {}(", copy rt, copy rt, copy f).as_str());
            text.append(fmt("{}, volt_r); }});\n", copy pass).as_str());
            text.append(fmt3("            {} *volt_p = std::launder(reinterpret_cast<{} *>(volt_r));\n            {} volt_v = std::move(*volt_p);\n", copy rt, copy rt, copy rt).as_str());
            text.append("            std::destroy_at(volt_p);\n            return volt_v;\n");
        } else if (m.ret.vty.as_str() == "void") {
            text.append(fmt2("            volt_cpp_enter([&]() {{ {}({}); }});\n", copy f, copy pass).as_str());
        } else if (m.ret.cast.len() > 0) {
            text.append(fmt3("            return ({})volt_cpp_enter([&]() {{ return {}({}); }});\n", copy m.ret.cast, copy f, copy pass).as_str());
        } else {
            text.append(fmt2("            return volt_cpp_enter([&]() {{ return {}({}); }});\n", copy f, copy pass).as_str());
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
    // (what every subclass uses, once: its name is in every subclass's)
    var once = true;
    for (n&) in this.c.cpp_decl_names.items() {
        once = once && n.as_str() != "volt_dir_";
    }
    if (once) {
        put(&this.c.cpp_decl_names, S("volt_dir_"));
        put(&this.c.cpp_decls, S(CPP_DIR_PRELUDE));
    }
    put(&this.c.cpp_decl_names, move dn);
    put(&this.c.cpp_decls, move text);
}

// the C++ subclass of q a Volt type derives (with _base: what every one has)
fn dir_name(q: str) -> std::string {
    var dn = S("volt_dir_");
    for (ch) in q {
        if (ch == ':') {
            dn.push('_');
        } else {
            dn.push(ch);
        }
    }
    return dn;
}

// ---------- enums ----------

attach fn enum_decl(this: cpp_gen&, c: clang::CXCursor) -> void {
    val name = cursor_name(c);
    // (newer libclang names an unnamed one "(unnamed enum at ...)")
    if (name.len() == 0 || clang::clang_Cursor_isAnonymous(c) != 0) {
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
        if (k == clang::CXCursor_Namespace && name.as_str() == "std") {
            p.append("stdcxx"); // Volt's own std stays visible to what the import writes
        } else {
            p.append(vname(name.as_str()).as_str());
        }
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
            if (name.as_str() == "std") {
                this.line("namespace stdcxx {");
            } else {
                this.line(fmt("namespace {} {{", vname(name.as_str())).as_str());
            }
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
        } else if (k == clang::CXCursor_TypedefDecl || k == clang::CXCursor_TypeAliasDecl) {
            // `using json = basic_json<>;`: a Volt alias for what it names, when that has a Volt
            // form (a class template's instance has one: its handle)
            val name = vname(cursor_name(*ch).as_str());
            val none: std::vec<str> = {};
            val v = this.vtype(clang::clang_getTypedefDeclUnderlyingType(*ch), &none);
            if (v) {
                if (v.as_str() != name.as_str() && this.first_time(fmt("type {}", copy name).as_str(), this.scope.as_str())) {
                    this.line(fmt2("type {} = {};", copy name, copy v).as_str());
                }
            }
        } else if (k == clang::CXCursor_ClassTemplate && clang::clang_isCursorDefinition(*ch) != 0 && this.tmpl_handles.get(cpp_qual(*ch).as_str()) != null) {
            this.template_handle(*ch);
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
        this.variable(v, true); // a variable C++ may change
        return;
    }
    val ev = clang::clang_Cursor_Evaluate(v);
    if (ev == null) {
        this.variable(v, false); // a constant clang can't work out
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
    } else {
        this.variable(v, false);
    }
}

// a namespace variable read (and when it can change, written) through wrappers: name() a reference
// into it for a number, bool, enum, pointer or class held by value (a borrowed handle for one held
// by handle), else name() a copy, and set_name(v); a constant clang can't work out (const
// std::string, const int x = f()) is name(), a copy
attach fn variable(this: cpp_gen&, v: clang::CXCursor, mutable: bool) -> void {
    val none: std::vec<str> = {};
    val t = clang::clang_getCursorType(v);
    if (t.kind == clang::CXType_LValueReference || t.kind == clang::CXType_RValueReference) {
        return;
    }
    val name = vname(cursor_name(v).as_str());
    val q = fmt("::{}", cpp_qual(v));
    if (!this.first_time(fmt("fn {}(", copy name).as_str(), "")) {
        return;
    }
    this.note = cpp_decl_text(v);
    if (mutable) {
        val hc = this.handle_of(t);
        if (hc) {
            val hv = this.vtype(t, &none) ?? return;
            val br: cpp_ret = { vty: move hv, way: ret_way::BORROWED, object: true, cls: copy hc };
            this.fn_text("", fmt2("fn {}() -> {}", copy name, copy br.vty).as_str(), &br, q.as_str(), "", "");
            return;
        }
        val pv = this.plain(t, &none);
        if (pv) {
            val rr: cpp_ret = { vty: fmt("{}&", copy pv) };
            this.fn_text("", fmt2("fn {}() -> {}", copy name, copy rr.vty).as_str(), &rr, q.as_str(), "", "");
            return;
        }
    }
    val r = this.result(t, &none) ?? return;
    if (this.copies_out(t)) {
        this.fn_text("", fmt2("fn {}() -> {}", copy name, copy r.vty).as_str(), &r, q.as_str(), "", "");
    }
    if (!mutable || !this.assignable(t)) {
        return;
    }
    val a = this.param(t, "v", 0, &none) ?? return;
    if (this.first_time(fmt("fn set_{}(", copy name).as_str(), fmt(",{}", copy a.vty).as_str())) {
        this.line(fmt2("fn set_{}(v: {}) -> void {{", copy name, copy a.vty).as_str());
        this.line(fmt3("    @cpp<void>(\"{} = {}\", {});", copy q, copy a.cpp, copy a.pass).as_str());
        this.line("}");
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
    if (this.closures) {
        this.line("// a closure a std::function field kept (closure_setter), deleted once C++ is done with it");
        this.line("<C: type>");
        this.line("fn volt_cpp_closure_drop(p: void*) -> void {");
        this.line("    val c: C* = @cast<C*>(p);");
        this.line("    val kept = @read(c);");
        this.line("    val a: std::mem::default_allocator = {};");
        this.line("    a.free<C>(c);");
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
    g.inst_src = copy src;
    g.inst_args = copy args;
    g.scan(tu.root(), "");
    g.probe(src.as_str(), &args);
    g.prune();
    g.instancing = true;
    g.pre_instances(tu.root());
    g.out.append(fmt("// the Volt side of use cpp {{ ... }} as {} (generated by voltc from the headers)\n", S(alias)).as_str());
    g.emit(tu.root());
    g.std_extras();
    g.flush_instances();
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
val CPP_PROBE_HEAD: str = "\n#include <cstddef>\n#include <functional>\n#include <string>\n#include <utility>\n#include <vector>\n#if __cplusplus >= 201103L\n#include <cstdint>\n#endif\n#if __cplusplus >= 201703L\n#include <string_view>\n#endif\ntemplate <class T> T &volt_lv();\ntemplate <class T> T volt_rv();\n#include <new>\n#if __cplusplus >= 201103L\n#include <iterator>\n#include <type_traits>\n#endif\n\n#if __cplusplus >= 201103L\n// a range Volt loops over (for (x) in r): what begin(r) and end(r) give (end's may be a sentinel), and\n// *it++ by value\nnamespace volt_rng {\nusing std::begin;\nusing std::end;\ntemplate <class R>\nauto b(R &r) -> decltype(begin(r)) {\n    return begin(r);\n}\ntemplate <class R>\nauto e(R &r) -> decltype(end(r)) {\n    return end(r);\n}\n}\ntemplate <class R>\nstruct volt_range_of {\n    typedef decltype(volt_rng::b(std::declval<R &>())) it;\n    typedef decltype(volt_rng::e(std::declval<R &>())) end;\n    typedef typename std::decay<decltype(*std::declval<it &>())>::type elem;\n};\ntemplate <class R>\nstatic void volt_range_start(R &r, void *it, void *end) {\n    new (it) typename volt_range_of<R>::it(volt_rng::b(r));\n    new (end) typename volt_range_of<R>::end(volt_rng::e(r));\n}\ntemplate <class R>\nstatic bool volt_range_done(void *it, void *end) {\n    return *(typename volt_range_of<R>::it *)it == *(typename volt_range_of<R>::end *)end;\n}\ntemplate <class R>\nstatic typename volt_range_of<R>::elem volt_range_take(void *it) {\n    typename volt_range_of<R>::it &i = *(typename volt_range_of<R>::it *)it;\n    typename volt_range_of<R>::elem v = *i;\n    ++i;\n    return v;\n}\n#endif\n";
// form_of's probe: a tuple-like's and a variant-like's size and elements, by the traits C++'s own
// library declares for them (void when a type has none)
val CPP_FORM_HEAD: str = "\n#if __cplusplus >= 201703L && defined(__has_include)\n#if __has_include(<variant>)\n#include <variant>\n#define VOLT_FORM_VARIANT 1\n#endif\n#endif\nnamespace volt_form {\ntemplate <bool B> struct when {};\ntemplate <> struct when<true> { typedef void type; };\ntemplate <class U, class = void> struct tsize { enum { v = 0 }; };\ntemplate <__SIZE_TYPE__ I, class U, class = void> struct telem { typedef void type; };\ntemplate <class U, class = void> struct vsize { enum { v = 0 }; };\ntemplate <__SIZE_TYPE__ I, class U, class = void> struct valt { typedef void type; };\n#if __cplusplus >= 201103L\ntemplate <class U> struct tsize<U, typename when<(std::tuple_size<U>::value > 0)>::type> { enum { v = std::tuple_size<U>::value }; };\ntemplate <__SIZE_TYPE__ I, class U> struct telem<I, U, typename when<(std::tuple_size<U>::value > I)>::type> { typedef typename std::tuple_element<I, U>::type type; };\n#endif\n#ifdef VOLT_FORM_VARIANT\ntemplate <class U> struct vsize<U, typename when<(std::variant_size<U>::value > 0)>::type> { enum { v = std::variant_size<U>::value }; };\ntemplate <__SIZE_TYPE__ I, class U> struct valt<I, U, typename when<(std::variant_size<U>::value > I)>::type> { typedef typename std::variant_alternative<I, U>::type type; };\n#endif\n}\n";
// ...and the rest, of type x with its type arguments a0, a1...: optional-like, contiguous
val CPP_FORM_PROBE: str = "template <class U> char (&opt(typename volt_form::when<__is_same(__decay(__decltype(*volt_lv<U>())), a0) && __is_constructible(U, const a0 &) && __is_constructible(U)>::type *, char (*)[sizeof(volt_lv<U>() ? 1 : 0)]))[2];\ntemplate <class U> char opt(...);\ntemplate <class U> char (&seq(typename volt_form::when<__is_same(__remove_cv(__remove_pointer(__decltype(volt_lv<U>().data()))), __remove_cv(a0))>::type *, char (*)[sizeof(volt_lv<U>().size())]))[2];\ntemplate <class U> char seq(...);\nenum {\n    o = sizeof(opt<x>(0, 0)) == 2,\n    s = sizeof(seq<x>(0, 0)) == 2,\n    v = __is_trivially_copyable(x) && sizeof(x) <= 2 * sizeof(void *),\n    fl = __is_constructible(x, __remove_cv(a0) *, __SIZE_TYPE__),\n    fr = __is_constructible(x, __remove_cv(a0) *, __remove_cv(a0) *),\n    t = volt_form::tsize<x>::v,\n    w = volt_form::vsize<x>::v,\n";

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
        .STRUCT(sid) => {
            val q = this.cpp_handle_of(sid);
            if (q) {
                return S(q);
            }
            return this.cpp_spell(t);
        },
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
    var unit_expr: std::string = {}; // the same in the wrappers' unit (a lambda's type is decltype of it)
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
                var moved = this.cpp_is_class(*types.at(hi));
                match (*this.t.get(*types.at(hi))) {
                    .STRUCT(sid) => { moved = moved || this.cpp_handle_of(sid) != null; },
                    default => {},
                }
                if (moved) {
                    probe_expr.append(fmt("volt_rv<{} >()", copy *ptys.at(hi)).as_str());
                    unit_expr.append(fmt("std::declval<{} >()", copy *ptys.at(hi)).as_str());
                } else {
                    probe_expr.append(fmt("volt_lv<{} >()", copy *ptys.at(hi)).as_str());
                    unit_expr.append(fmt("std::declval<{} &>()", copy *ptys.at(hi)).as_str());
                }
                i = e + 1;
                continue;
            }
        }
        probe_expr.push(expr[i]);
        unit_expr.push(expr[i]);
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
    if (by_value) {
        g.unnamed_as = fmt("std::decay<decltype({})>::type", copy unit_expr);
    } else {
        g.unnamed_as = fmt("std::remove_reference<decltype({})>::type", copy unit_expr);
    }
    if (g.inst_args.len == 0) {
        g.inst_src = copy this.cpp_ctxs.at(k).src;
        g.inst_args = copy this.cpp_ctxs.at(k).args;
    }
    g.instancing = true;
    g.inst_any = true;
    val r = g.result(rt, &none);
    g.unnamed_as = {};
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
        g.inst_any = false;
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
    g.inst_any = false;
    g.flush_instances();
    var out = copy g.out;
    g.out = {};
    if (std::process::env("VOLT_SHOW_CPP") != null) {
        std::eprint("{}", out);
    }
    var fl = S("<C++ call ");
    fl.append(expr);
    fl.push('>');
    val first = try this.cpp_declare(k, move out, move fl);
    var d: u32? = null;
    for (j) in first..this.decls.len {
        val fd = this.fn_decl_of(@cast<u32>(j));
        if (fd != null && d == null) {
            d = @cast<u32>(j);
        }
    }
    val made = d ?? return fails(span, "the C++ call's Volt fn wasn't declared");
    this.cpp_dyn.put(this.intern(move key), made);
    this.cpp_dyn_ret.put(made, this.intern(copy rr.vty));
    return made;
}

// Volt source written for import k (a call made per use, a range's iterator), declared in its
// namespace as the import's own declarations are; the first of the decls it made
attach fn cpp_declare(this: checker&, k: usize, text: std::string, label: std::string) -> compile_error!usize {
    put(&this.c_texts, move text);
    val src = this.c_texts.at(this.c_texts.len - 1).as_str();
    put(this.files, { name: this.intern(move label), text: src });
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
    return first;
}

// for (x) in r over a C++ range Volt holds by handle (what begin(r) and end(r) take): an iterator
// struct for its type, holding its begin and end iterators in its own words, whose next gives *it++
// as the value it reads as in Volt; and volt_range(this: R&), which starts one. Whether r is one
// (an iterator that isn't trivially copyable and destructible, which nearly all are, can't be held
// so: an error says)
attach fn cpp_range(this: checker&, t: u32, span: span) -> compile_error!bool {
    var sid: u32 = 0;
    match (*this.t.get(t)) {
        .STRUCT(x) => { sid = x; },
        default => { return false; },
    }
    val q = this.cpp_handle_of(sid) ?? return false;
    val k = this.cpp_ctx_of(this.decls.at(@cast<usize>(this.si(sid).decl)).ns) ?? return false;
    val rk = this.intern(fmt2("{}:{}", unum(@cast<u64>(k)), S(q)));
    if (this.cpp_ranges.get(rk) != null) {
        return true;
    }
    // the iterators' sizes, and whether Volt can hold them
    val x = this.cpp_ctxs.at(k);
    var text = copy x.src;
    text.append(CPP_PROBE_HEAD);
    text.append("namespace volt_range_q {\n");
    text.append(fmt2("typedef volt_range_of<{} >::it it;\ntypedef volt_range_of<{} >::end end;\n", S(q), S(q)).as_str());
    text.append("enum {\n    ok = __is_trivially_copyable(it) && __is_trivially_destructible(it) && __is_trivially_copyable(end) && __is_trivially_destructible(end) && __alignof(it) <= 8 && __alignof(end) <= 8,\n    si = sizeof(it),\n    se = sizeof(end),\n};\n}\n");
    val main = "volt_cpp_call.cpp";
    if (x.probe.tu == null || !x.probe.reparse(main, text.as_str())) {
        x.probe = clang_parse_opts(main, text.as_str(), &x.args, 260);
    }
    val errs = x.probe.errors_text(main);
    if (errs) {
        return fail(span, fmt2("can't loop over C++'s {}: begin(r) and end(r) don't take it (a range needs C++11 or newer):\n{}", S(q), copy errs));
    }
    var ok = false;
    var si: u64 = 0;
    var se: u64 = 0;
    for (ns&) in children(x.probe.root()).items() {
        if (clang::clang_getCursorKind(*ns) != clang::CXCursor_Namespace || cursor_name(*ns).as_str() != "volt_range_q") {
            continue;
        }
        for (e&) in children(*ns).items() {
            if (clang::clang_getCursorKind(*e) != clang::CXCursor_EnumDecl) {
                continue;
            }
            for (c&) in children(*e).items() {
                val v = clang::clang_getEnumConstantDeclValue(*c);
                val w = cursor_name(*c);
                if (w.as_str() == "ok") {
                    ok = v != 0;
                } else if (w.as_str() == "si") {
                    si = @cast<u64>(v);
                } else if (w.as_str() == "se") {
                    se = @cast<u64>(v);
                }
            }
        }
    }
    if (!ok) {
        return fail(span, fmt("can't loop over C++'s {}: its iterators aren't trivially copyable and destructible (with alignment 8 at most), so a Volt loop can't hold them", S(q)));
    }
    // *it++, as what it reads as in Volt (a call made per use)
    var types: std::vec<u32> = {};
    put(&types, VOIDPTR);
    val take = try this.cpp_instance(k, fmt("volt_range_take<{} >({{0}})", S(q)).as_str(), &types, false, true, span);
    val fd = this.fn_decl_of(take) ?? return fails(span, "the range's Volt fn wasn't declared");
    val elem = *(this.cpp_dyn_ret.get(take) ?? return fails(span, "the range's Volt fn has no result"));
    val n = unum(@cast<u64>(this.cpp_ranges.len));
    val vn = fmt("volt_range_{}", copy n);
    var out = fmt("// C++'s {} looped over: its begin and end iterators, in its own words\n", S(q));
    out.append(fmt3("struct {} {{\n    it: u64[{}];\n    end: u64[{}];\n}}\n", copy vn, unum((si + 7) / 8), unum((se + 7) / 8)).as_str());
    out.append(fmt2("attach fn next(this: {}&) -> {}? {{\n", copy vn, S(elem)).as_str());
    out.append(fmt("    if (@cpp<bool>(\"volt_range_done<{} >({{0}}, {{1}})\", @cast<void*>(&this.it), @cast<void*>(&this.end))) {{\n        return null;\n    }}\n", S(q)).as_str());
    out.append(fmt("    return {}(@cast<void*>(&this.it));\n}}\n", S(fd->name)).as_str());
    out.append(fmt2("attach fn volt_range(this: {}&) -> {} {{\n", this.ty_name(t), copy vn).as_str());
    out.append(fmt("    var out: {};\n", copy vn).as_str());
    out.append(fmt2("    @cpp<void>(\"volt_range_start(volt_cpp_obj<{} >({{0}}), {{1}}, {{2}})\", this.cpp, @cast<void*>(&out.it), @cast<void*>(&out.end));\n    return out;\n}}\n", S(q), S("")).as_str());
    if (std::process::env("VOLT_SHOW_CPP") != null) {
        std::eprint("{}", out);
    }
    this.cpp_ranges.put(rk, true);
    try this.cpp_declare(k, move out, fmt("<C++ range {}>", S(q)));
    return true;
}

// a call of an @cpp_call declaration (d): the C++ it names, with these arguments and explicit
// template arguments, made per use (cpp_instance) and called like any fn
attach fn cpp_dyn_call(this: checker&, d: u32, name: str, rv: tval?, explicit: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    var callee = this.cpp_call_attr(d) ?? "";
    // "c:NAME": a C import's (cuse.volt)
    if (starts_with(callee, "c:")) {
        return this.c_dyn_call(d, callee[2..callee.len], name, explicit, args, want, span);
    }
    // "#NAME" is a function-like macro: what it expands to comes back by value
    val macro = starts_with(callee, "#");
    if (macro) {
        callee = callee[1..callee.len];
    }
    val k = this.cpp_ctx_of(this.decls.at(@cast<usize>(d)).ns) ?? return fails(span, "this C++ name's import is gone");
    return this.cpp_use_call(k, callee, macro, name, rv, explicit, args, want, span);
}

// a call of callee (ns::f, or .m on rv) worked out per use in import k's headers
attach fn cpp_use_call(this: checker&, k: usize, callee: str, macro: bool, name: str, rv: tval?, explicit: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
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
        // an operator by its Volt name (op_add): C++'s own syntax, which a member or free operator
        // and a lambda's call all take
        val op = cpp_operator(callee, args.len);
        if (op) {
            expr = copy op;
            if (!ends_with(expr.as_str(), "(")) {
                // a whole expression: its operands are the holes already
                for (j) in 0..args.len {
                    val v = try this.expr(args.at(j), null);
                    put(&types, v.ty);
                    put(&pre, v);
                }
                val made = try this.cpp_instance(k, expr.as_str(), &types, true, macro, span);
                var cands: std::vec<u32> = {};
                put(&cands, made);
                var none: std::vec<garg> = {};
                return this.pick_call(name, &cands, rp, null, &none, &pre, args, want, span);
            }
        }
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
        val sp = this.cpp_type_text(t) ?? return fail(span, fmt("@cpp: {} has no C++ spelling", this.ty_name(t)));
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
        // what it throws: a try_ form's error, rethrown to C++ that called into Volt, or a stop
        // (volt_cpp_caught); then a zero value
        var zero = S("    return;\n");
        if (rsp.as_str() != "void") {
            zero = fmt("    return volt_cpp_zero<{} >();\n", copy rsp);
        }
        w.append(fmt2("    try {{\n        {}\n    }} catch (...) {{\n        volt_cpp_caught();\n    }}\n    volt_cpp_after();\n{}}}\n", copy body, move zero).as_str());
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
val CPP_UNIT_HEAD: str = "#include <algorithm>\n#include <csetjmp>\n#include <cstddef>\n#include <cstdio>\n#include <cstdlib>\n#include <cstring>\n#include <exception>\n#include <functional>\n#include <memory>\n#include <new>\n#include <stdexcept>\n#include <stdint.h>\n#include <string>\n#include <typeinfo>\n#include <utility>\n#include <vector>\n#if __cplusplus >= 201103L\n#include <cstdint>\n#include <type_traits>\n#endif\n#if __cplusplus >= 201703L\n#include <string_view>\n#endif\n#if __has_include(<cxxabi.h>)\n#include <cxxabi.h>\n#endif\n\n// RTTI (dynamic_cast, typeid): only what needs it uses it, and a build without it (-fno-rtti) has the rest\n#if defined(__GXX_RTTI) || defined(__cpp_rtti) || defined(_CPPRTTI)\n#define VOLT_RTTI 1\n#else\n#define VOLT_RTTI 0\n#endif\n\n// what the wrappers write differently by standard: a move, a type spelled anywhere, an expression's\n// type without its reference (C++98 has no moves, decltype or alias templates)\ntemplate <class T>\nstruct volt_idt {\n    typedef T type;\n};\n\n#if __cplusplus >= 201103L\n#define VOLT_MOVE(...) std::move(__VA_ARGS__)\n#define VOLT_NOREF(...) std::remove_reference<decltype(__VA_ARGS__)>::type\n#define VOLT_NORETURN [[noreturn]]\n#define VOLT_TLS thread_local\n#else\n#define VOLT_MOVE(...) (__VA_ARGS__)\n#define VOLT_NOREF(...) __typeof__(__VA_ARGS__)\n#define VOLT_NORETURN __attribute__((noreturn))\n#define VOLT_TLS\n#endif\n#define VOLT_ID(...) volt_idt<__VA_ARGS__ >::type\n";

// after the headers: what the wrappers call
// what Volt's subclasses of C++ classes (derive) use, in a unit that has one
val CPP_DIR_PRELUDE: str = "\n// what Volt's subclasses of C++ classes (derive) do to an object as what it is (its class's\n// destructor needn't be virtual): copy it (out: the copy's Volt side; null when its Volt type can't\n// be copied), delete it, and name its type (the Volt type's). A derived object's Volt side starts with\n// its subclass's, and a table by address knows one C++ handed back (any standard compiles this; only\n// C++17 and newer have subclasses). One table for all of a program's C++ units\nstruct volt_dir_ops {\n    void *(*copy)(void *o, void **out);\n    void (*del)(void *o);\n    std::string (*name)(void *o);\n    const void *tag; // the subclass's (volt_dir_find)\n};\n\n#if __cplusplus >= 201703L\n#include <mutex>\n#include <unordered_map>\n\nstruct volt_dir_reg {\n    std::mutex m;\n    std::unordered_map<const void *, const volt_dir_ops *> objs;\n};\nextern \"C\" {\n__attribute__((weak)) volt_dir_reg *volt_dir_regs = 0;\n}\n\n// an object derive made, or (ops null) one going\nstatic void volt_dir_put(const void *p, const volt_dir_ops *ops) {\n    volt_dir_reg *r = __atomic_load_n(&volt_dir_regs, __ATOMIC_ACQUIRE);\n    if (!r) {\n        volt_dir_reg *n = new volt_dir_reg(); // (never deleted: objects can outlive static destructors)\n        if (__atomic_compare_exchange_n(&volt_dir_regs, &r, n, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {\n            r = n;\n        } else {\n            delete n;\n        }\n    }\n    std::lock_guard<std::mutex> g(r->m);\n    if (ops) {\n        r->objs[p] = ops;\n    } else {\n        r->objs.erase(p);\n    }\n}\n#endif\n\n// a handle's object's ops, when derive made it: the handle's Volt side has them, else the table\nstatic const volt_dir_ops *volt_dir_lookup(void *p, void *volt) {\n    if (volt) {\n        return *(const volt_dir_ops *const *)volt;\n    }\n#if __cplusplus >= 201703L\n    volt_dir_reg *r = __atomic_load_n(&volt_dir_regs, __ATOMIC_ACQUIRE);\n    if (p && r) {\n        std::lock_guard<std::mutex> g(r->m);\n        std::unordered_map<const void *, const volt_dir_ops *>::iterator i = r->objs.find(p);\n        if (i != r->objs.end()) {\n            return i->second;\n        }\n    }\n#endif\n    (void)p;\n    return 0;\n}\n\n// a handle's object deleted, copied and named: one derive made as what it is, another as a B (as C++\n// would through a B; C: B can be copied from outside it)\ntemplate <class B>\nstatic void volt_dir_delete(void *p, void *volt) {\n    if (const volt_dir_ops *o = volt_dir_lookup(p, volt)) {\n        o->del(p);\n    } else {\n        delete (B *)p;\n    }\n}\n\ntemplate <class B, bool C>\nstruct volt_dir_plain {\n    static void *copy(void *p) { return new B(volt_cpp_obj<B>(p)); }\n};\n\ntemplate <class B>\nstruct volt_dir_plain<B, false> {\n    static void *copy(void *) {\n        std::fprintf(stderr, \"panic: a C++ object derive didn't make copied, and only a subclass can copy its class\\n\");\n        std::exit(101);\n    }\n};\n\ntemplate <class B, bool C>\nstatic void *volt_dir_copy(void *p, void *volt, void **out) {\n    *out = 0;\n    if (const volt_dir_ops *o = volt_dir_lookup(p, volt)) {\n        void *c = o->copy(p, out);\n        if (!c) {\n            std::fprintf(stderr, \"panic: a C++ object derive made copied, and its Volt type can't be copied\\n\");\n            std::exit(101);\n        }\n        return c;\n    }\n    return volt_dir_plain<B, C>::copy(p);\n}\n\ntemplate <class B>\nstatic std::string volt_dir_name(void *p, void *volt) {\n    if (const volt_dir_ops *o = volt_dir_lookup(p, volt)) {\n        return o->name(p);\n    }\n    return volt_cpp_type_name(volt_cpp_obj<B>(p));\n}\n\n#if __cplusplus >= 201703L\n// the subclass D (of B) behind a handle, when derive made the object as one: for a protected member,\n// and the Volt side (derived<T>())\ntemplate <class D, class B>\nstatic D *volt_dir_find(void *p, void *volt) {\n    const volt_dir_ops *o = volt_dir_lookup(p, volt);\n    return o && o->tag == &D::volt_tag ? static_cast<D *>((B *)p) : 0;\n}\n\ntemplate <class D, class B>\nstatic D &volt_dir_of(void *p, void *volt) {\n    volt_cpp_obj<B>(p);\n    if (D *d = volt_dir_find<D, B>(p, volt)) {\n        return *d;\n    }\n    std::fprintf(stderr, \"panic: a protected member of a C++ object Volt didn't make with derive\\n\");\n    std::exit(101);\n}\n\ntemplate <class D, class B>\nstatic void *volt_dir_block(void *p) {\n    D *d = volt_dir_find<D, B>(p, 0);\n    return d ? d->volt_d : 0;\n}\n#endif\n";

val CPP_PRELUDE: str = "\n// an exception that reaches Volt stops the program, like a panic\nVOLT_NORETURN static void volt_cpp_throw(const char *what) {\n    std::fprintf(stderr, \"panic: C++ exception: %s\\n\", what);\n    std::exit(101);\n}\n\n// the object behind a handle (Volt holds a class that isn't trivially copyable by pointer)\ntemplate <class T>\nstatic T &volt_cpp_obj(void *p) {\n    if (!p) {\n        std::fprintf(stderr, \"panic: a C++ object Volt holds by handle was never made (its handle is empty)\\n\");\n        std::exit(101);\n    }\n    return *(T *)p;\n}\n\n// C++ exceptions and Volt. Every wrapper catches what its call throws (volt_cpp_caught): in a try_\n// form's call (catch mode: kinds, the import's function numbering exceptions) it records which and\n// returns a zero value, the try_ form returning the error; inside a call C++ made into Volt (jump:\n// that call's, volt_cpp_enter) it keeps the exception (pending) and, once out of its catch, jumps\n// back there, and C++ gets it rethrown with its own type (the Volt frames between are left, their\n// deletes not run); otherwise it stops the program, like a panic. One state for all of a program's\n// C++ units, whatever their standards\nstruct volt_cpp_state {\n    int (*kinds)();\n    int kind;\n    void *jump;    // a std::jmp_buf\n    void *pending; // a std::exception_ptr\n};\nextern \"C\" {\n__attribute__((weak)) __thread volt_cpp_state volt_cpp_st = {0, 0, 0, 0};\n}\n\ntemplate <class T>\nstatic T volt_cpp_zero() {\n    return T();\n}\n\nstatic void volt_cpp_caught() {\n    if (volt_cpp_st.kinds) {\n        if (!volt_cpp_st.kind) {\n            volt_cpp_st.kind = volt_cpp_st.kinds();\n        }\n        return;\n    }\n#if __cplusplus >= 201103L\n    if (volt_cpp_st.jump) {\n        if (!volt_cpp_st.pending) {\n            volt_cpp_st.pending = new std::exception_ptr(std::current_exception());\n        }\n        return;\n    }\n#endif\n    try {\n        throw;\n    } catch (const std::exception &e) {\n        volt_cpp_throw(e.what());\n    } catch (...) {\n        volt_cpp_throw(\"an exception that isn't a std::exception\");\n    }\n}\n\nstatic void volt_cpp_after() {\n#if __cplusplus >= 201103L\n    if (volt_cpp_st.pending && volt_cpp_st.jump) {\n        std::longjmp(*(std::jmp_buf *)volt_cpp_st.jump, 1);\n    }\n#endif\n}\n\n// a try_ form: catch mode on (the mode it was in comes back to be put back), then which exception\n// its call threw (0: none)\nstatic void *volt_cpp_catch_begin(int (*kinds)()) {\n    void *prev = (void *)volt_cpp_st.kinds;\n    volt_cpp_st.kinds = kinds;\n    volt_cpp_st.kind = 0;\n    return prev;\n}\n\nstatic int volt_cpp_catch_end(void *prev) {\n    int k = volt_cpp_st.kind;\n    volt_cpp_st.kinds = (int (*)())prev;\n    volt_cpp_st.kind = 0;\n    return k;\n}\n\n#if __cplusplus >= 201103L\n// C++ calling Volt (f): where an exception thrown in a C++ call the Volt code makes comes back to,\n// to be rethrown here\ntemplate <class R>\nstruct volt_cpp_leave {\n    template <class F>\n    static R run(F &f, const volt_cpp_state &saved) {\n        R r = f();\n        volt_cpp_st = saved;\n        return r;\n    }\n};\n\ntemplate <>\nstruct volt_cpp_leave<void> {\n    template <class F>\n    static void run(F &f, const volt_cpp_state &saved) {\n        f();\n        volt_cpp_st = saved;\n    }\n};\n\ntemplate <class F>\nstatic auto volt_cpp_enter(F f) -> decltype(f()) {\n    std::jmp_buf jb;\n    const volt_cpp_state saved = volt_cpp_st;\n    if (setjmp(jb) != 0) {\n        std::exception_ptr *p = (std::exception_ptr *)volt_cpp_st.pending;\n        volt_cpp_st = saved;\n        std::exception_ptr e = *p;\n        delete p;\n        std::rethrow_exception(e);\n    }\n    volt_cpp_st.kinds = 0;\n    volt_cpp_st.kind = 0;\n    volt_cpp_st.jump = &jb;\n    volt_cpp_st.pending = 0;\n    return volt_cpp_leave<decltype(f())>::run(f, saved);\n}\n#endif\n\n// Volt's str and T[..]\nstruct volt_str {\n    const unsigned char *ptr;\n    size_t len;\n};\n\ntemplate <class T>\nstruct volt_slice {\n    T *ptr;\n    size_t len;\n};\n\n// text copied out of C++, in memory the Volt side frees (std::free); and a view's bytes\nstatic inline volt_str volt_cpp_dup(const char *s, size_t n) {\n    unsigned char *p = (unsigned char *)std::malloc(n ? n : 1);\n    if (!p) {\n        volt_cpp_throw(\"out of memory\");\n    }\n    std::memcpy(p, s, n);\n    volt_str r = {p, n};\n    return r;\n}\n\nstatic inline volt_str volt_cpp_view(const char *s, size_t n) {\n    volt_str r = {(const unsigned char *)s, n};\n    return r;\n}\n\n#if __cplusplus >= 201703L\nstatic inline volt_str volt_cpp_dup(std::string_view s) {\n    return volt_cpp_dup(s.data(), s.size());\n}\n\nstatic inline volt_str volt_cpp_view(std::string_view s) {\n    return volt_cpp_view(s.data(), s.size());\n}\n#else\nstatic inline volt_str volt_cpp_dup(const std::string &s) {\n    return volt_cpp_dup(s.data(), s.size());\n}\n\nstatic inline volt_str volt_cpp_dup(const char *s) {\n    return volt_cpp_dup(s, std::strlen(s));\n}\n\nstatic inline volt_str volt_cpp_view(const std::string &s) {\n    return volt_cpp_view(s.data(), s.size());\n}\n\nstatic inline volt_str volt_cpp_view(const char *s) {\n    return volt_cpp_view(s, std::strlen(s));\n}\n#endif\n\n// a std::vector's elements copied out the same way\ntemplate <class T>\nstatic volt_slice<T> volt_cpp_dup_vec(const std::vector<T> &v) {\n#if __cplusplus >= 201103L\n    static_assert(std::is_trivially_copyable<T>::value, \"Volt copies out a std::vector of plain values\");\n#endif\n    T *p = (T *)std::malloc(sizeof(T) * (v.size() ? v.size() : 1));\n    if (!p) {\n        volt_cpp_throw(\"out of memory\");\n    }\n    std::copy(v.begin(), v.end(), p);\n    volt_slice<T> r = {p, v.size()};\n    return r;\n}\n\n// the types Volt reads by what they can do (form_of in voltc): an optional-like's value, a\n// contiguous one's elements (viewed where they are, or copied out into memory the Volt side frees),\n// a fixed-size one's, a tuple-like's and a variant-like's, into the Volt side's locals; and an\n// optional-like, contiguous or fixed-size one made from Volt's\ntemplate <class O, class T>\nstatic bool volt_cpp_opt_out(const O &o, T &out) {\n    if (!(o ? true : false)) {\n        return false;\n    }\n    out = (T)(*o);\n    return true;\n}\n\ntemplate <class T>\nstruct volt_opt {\n    T v;\n    bool has;\n};\n\ntemplate <class O, class T>\nstatic O volt_cpp_opt_in(const void *p) {\n    const volt_opt<T> *o = (const volt_opt<T> *)p;\n    if (o->has) {\n        return O(o->v);\n    }\n    return O();\n}\n\ntemplate <class C>\nstruct volt_seq {\n    const C &c;\n    bool dup;\n    template <class T>\n    operator volt_slice<T>() const {\n        size_t n = c.size();\n        T *p = (T *)c.data();\n        if (dup) {\n            p = (T *)std::malloc(sizeof(T) * (n ? n : 1));\n            if (!p) {\n                volt_cpp_throw(\"out of memory\");\n            }\n            for (size_t i = 0; i < n; i++) {\n                p[i] = (T)c.data()[i];\n            }\n        }\n        volt_slice<T> r = {p, n};\n        return r;\n    }\n    operator volt_str() const {\n        if (dup) {\n            return volt_cpp_dup((const char *)c.data(), c.size());\n        }\n        return volt_cpp_view((const char *)c.data(), c.size());\n    }\n};\n\ntemplate <class C>\nstatic volt_seq<C> volt_cpp_seq_view(const C &c) {\n    volt_seq<C> s = {c, false};\n    return s;\n}\n\ntemplate <class C>\nstatic volt_seq<C> volt_cpp_seq_dup(const C &c) {\n    volt_seq<C> s = {c, true};\n    return s;\n}\n\ntemplate <class C>\nstatic void volt_cpp_copy_out(const C &c, void *out) {\n    std::memcpy(out, (const void *)c.data(), sizeof(*c.data()) * c.size());\n}\n\ntemplate <class C>\nstatic C volt_cpp_copy_in(const void *p) {\n    C c;\n    std::memcpy((void *)c.data(), p, sizeof(*c.data()) * c.size());\n    return c;\n}\n\n#if __cplusplus >= 201103L\ntemplate <size_t I, class P>\nstatic void volt_cpp_get(const P &) {}\n\ntemplate <size_t I, class P, class T, class... R>\nstatic void volt_cpp_get(const P &p, T &out, R &... rest) {\n    using std::get;\n    out = (T)(get<I>(p));\n    volt_cpp_get<I + 1>(p, rest...);\n}\n\ntemplate <size_t I, class V>\nstatic void volt_cpp_alt(const V &, size_t) {}\n\ntemplate <size_t I, class V, class T, class... R>\nstatic void volt_cpp_alt(const V &v, size_t i, T &out, R &... rest) {\n    using std::get;\n    if (i == I) {\n        out = (T)(get<I>(v));\n    } else {\n        volt_cpp_alt<I + 1>(v, i, rest...);\n    }\n}\n\ntemplate <class V, class... T>\nstatic size_t volt_cpp_variant_out(const V &v, T &... out) {\n    size_t i = v.index();\n    if (i >= sizeof...(T)) {\n        volt_cpp_throw(\"a variant with no value (valueless by exception)\");\n    }\n    volt_cpp_alt<0>(v, i, out...);\n    return i;\n}\n#endif\n\n#if __cplusplus >= 201103L\n// std::function and Volt: a Volt fn(...) value is its function (taking the env first) and its env;\n// what a Volt function takes and gives for a C++ type (text as volt_str, an enum as its integer)\nstruct volt_fnval {\n    void *fn;\n    void *env;\n};\n\ntemplate <class T, class = void>\nstruct volt_abi {\n    typedef T type;\n    static T in(T v) { return v; }\n    static T out(T v) { return v; }\n};\n\ntemplate <class T>\nstruct volt_abi<T, typename std::enable_if<std::is_enum<T>::value>::type> {\n    typedef typename std::underlying_type<T>::type type;\n    static type in(T v) { return (type)v; }\n    static T out(type v) { return (T)v; }\n};\n\n#if __cplusplus >= 201703L\ntemplate <>\nstruct volt_abi<std::string_view> {\n    typedef volt_str type;\n    static volt_str in(std::string_view s) { return volt_cpp_view(s); }\n};\n#endif\n\ntemplate <>\nstruct volt_abi<std::string> {\n    typedef volt_str type;\n    static volt_str in(const std::string &s) { return volt_cpp_view(s); }\n};\n\n// a call of the Volt fn f, giving R (or nothing)\ntemplate <class R, class... A>\nstruct volt_call {\n    static R run(volt_fnval f, A... a) {\n        typedef typename volt_abi<R>::type (*Fn)(void *, typename volt_abi<typename std::decay<A>::type>::type...);\n        return volt_abi<R>::out(volt_cpp_enter([&]() { return ((Fn)f.fn)(f.env, volt_abi<typename std::decay<A>::type>::in(a)...); }));\n    }\n};\n\ntemplate <class... A>\nstruct volt_call<void, A...> {\n    static void run(volt_fnval f, A... a) {\n        volt_cpp_enter([&]() { ((void (*)(void *, typename volt_abi<typename std::decay<A>::type>::type...))f.fn)(f.env, volt_abi<typename std::decay<A>::type>::in(a)...); });\n    }\n};\n\n// a Volt fn value (at p) as a std::function\ntemplate <class R, class... A>\nstatic std::function<R(A...)> volt_cpp_fn(void *p) {\n    volt_fnval f = *(volt_fnval *)p;\n    return [f](A... a) -> R { return volt_call<R, A...>::run(f, a...); };\n}\n\n// a std::function a field keeps: the closure's function (fv's) with the boxed closure as its env,\n// the box deleted by drop when the last copy goes\ntemplate <class S>\nstruct volt_owned_fn_of;\n\ntemplate <class R, class... A>\nstruct volt_owned_fn_of<R(A...)> {\n    static std::function<R(A...)> make(void *fv, void *box, void (*drop)(void *)) {\n        volt_fnval f = *(volt_fnval *)fv;\n        f.env = box;\n        std::shared_ptr<void> keep(box, drop);\n        return [f, keep](A... a) -> R { return volt_call<R, A...>::run(f, a...); };\n    }\n};\n\ntemplate <class S>\nstatic std::function<S> volt_cpp_owned_fn(void *fv, void *box, void (*drop)(void *)) {\n    return volt_owned_fn_of<S>::make(fv, box, drop);\n}\n\n// a std::function C++ gave Volt (stdcxx::function), and its callable for one signature (sig: that\n// signature's tag)\ntemplate <class S>\nstruct volt_sig {\n    static char tag;\n};\n\ntemplate <class S>\nchar volt_sig<S>::tag = 0;\n\nstruct volt_fn_box {\n    const void *sig;\n    explicit volt_fn_box(const void *s) : sig(s) {}\n    virtual ~volt_fn_box() = default;\n};\n\ntemplate <class S>\nstruct volt_fn_holder : volt_fn_box {\n    std::function<S> f;\n    volt_fn_holder(std::function<S> g) : volt_fn_box(&volt_sig<S>::tag), f(std::move(g)) {}\n};\n\ntemplate <class S>\nstatic std::function<S> &volt_cpp_holder(void *p) {\n    volt_fn_box *b = (volt_fn_box *)p;\n    volt_fn_holder<S> *h = b && b->sig == &volt_sig<S>::tag ? static_cast<volt_fn_holder<S> *>(b) : nullptr;\n    if (!h) {\n        std::fprintf(stderr, \"panic: a stdcxx::function called with another signature's arguments, or empty\\n\");\n        std::exit(101);\n    }\n    return h->f;\n}\n#endif\n\n// what the exception a try_ form caught said (a kinds function sets it)\nstatic VOLT_TLS std::string volt_cpp_last;\n\n\n// a handle's object for a by-value parameter: moved from when the handle owns it, copied when it\n// only borrows it (as_Base's: the object is something else's) and Volt found it copies (C: C++'s\n// is_copy_constructible says yes for a class whose copy doesn't compile)\nstruct volt_handle {\n    void *cpp;\n    bool borrowed;\n};\n\n#if __cplusplus >= 201103L\ntemplate <class T>\nstatic T volt_cpp_copy(T &o, std::true_type) {\n    return o;\n}\n\ntemplate <class T>\nstatic T volt_cpp_copy(T &, std::false_type) {\n    std::fprintf(stderr, \"panic: a borrowed C++ object passed by value, and it can't be copied\\n\");\n    std::exit(101);\n}\n#endif\n\ntemplate <class T, bool C>\nstatic T volt_cpp_take(void *h) {\n    volt_handle *v = (volt_handle *)h;\n    T &o = volt_cpp_obj<T>(v->cpp);\n#if __cplusplus >= 201103L\n    if (v->borrowed) {\n        return volt_cpp_copy(o, std::integral_constant<bool, C>());\n    }\n    return std::move(o);\n#else\n    return o; // no moves before C++11: copied either way\n#endif\n}\n\n// what needs RTTI: an object's dynamic type's name, a cast to a derived class (without RTTI they stop\n// the program, when called)\nVOLT_NORETURN static void volt_cpp_no_rtti(const char *what) {\n    std::fprintf(stderr, \"panic: %s needs RTTI, and the C++ was built without it (-fno-rtti)\\n\", what);\n    std::exit(101);\n}\n\ntemplate <class D, class B>\nstatic D *volt_cpp_down(B *p) {\n#if VOLT_RTTI\n    return dynamic_cast<D *>(p);\n#else\n    volt_cpp_no_rtti(\"a cast to a derived class (as_)\");\n#endif\n}\n\nstatic inline std::string volt_cpp_demangle(const char *name);\n\ntemplate <class T>\nstatic std::string volt_cpp_type_name(const T &o) {\n#if VOLT_RTTI\n    return volt_cpp_demangle(typeid(o).name());\n#else\n    volt_cpp_no_rtti(\"cpp_type_name\");\n#endif\n}\n\n// a type's name as C++ writes it (typeid's, demangled where the C++ library can)\nstatic inline std::string volt_cpp_demangle(const char *name) {\n#if __has_include(<cxxabi.h>)\n    int status = 0;\n    char *d = abi::__cxa_demangle(name, 0, 0, &status);\n    if (d) {\n        std::string s = d;\n        std::free(d);\n        return s;\n    }\n#endif\n    return name;\n}\n\n// Volt's subclasses of C++ classes (derive): a type spelled anywhere\n#if __cplusplus >= 201103L\ntemplate <class T>\nusing volt_id = T;\n#endif\n\n#if __cplusplus >= 201103L\n#include <iterator>\n#endif\n\n#if __cplusplus >= 201103L\n// a range Volt loops over (for (x) in r): what begin(r) and end(r) give (end's may be a sentinel), and\n// *it++ by value\nnamespace volt_rng {\nusing std::begin;\nusing std::end;\ntemplate <class R>\nauto b(R &r) -> decltype(begin(r)) {\n    return begin(r);\n}\ntemplate <class R>\nauto e(R &r) -> decltype(end(r)) {\n    return end(r);\n}\n}\ntemplate <class R>\nstruct volt_range_of {\n    typedef decltype(volt_rng::b(std::declval<R &>())) it;\n    typedef decltype(volt_rng::e(std::declval<R &>())) end;\n    typedef typename std::decay<decltype(*std::declval<it &>())>::type elem;\n};\ntemplate <class R>\nstatic void volt_range_start(R &r, void *it, void *end) {\n    new (it) typename volt_range_of<R>::it(volt_rng::b(r));\n    new (end) typename volt_range_of<R>::end(volt_rng::e(r));\n}\ntemplate <class R>\nstatic bool volt_range_done(void *it, void *end) {\n    return *(typename volt_range_of<R>::it *)it == *(typename volt_range_of<R>::end *)end;\n}\ntemplate <class R>\nstatic typename volt_range_of<R>::elem volt_range_take(void *it) {\n    typename volt_range_of<R>::it &i = *(typename volt_range_of<R>::it *)it;\n    typename volt_range_of<R>::elem v = *i;\n    ++i;\n    return v;\n}\n#endif\n\n#if __cplusplus >= 201103L\n// a Volt tuple's field I, where C lays out a struct of the fields T...\ntemplate <size_t I, size_t At, class... T>\nstruct volt_field;\ntemplate <size_t At, class F, class... T>\nstruct volt_field<0, At, F, T...> {\n    static const size_t at = (At + alignof(F) - 1) / alignof(F) * alignof(F);\n    typedef F type;\n};\ntemplate <size_t I, size_t At, class F, class... T>\nstruct volt_field<I, At, F, T...> : volt_field<I - 1, (At + alignof(F) - 1) / alignof(F) * alignof(F) + sizeof(F), T...> {};\ntemplate <size_t I, class... T>\nstatic const typename volt_field<I, 0, T...>::type &volt_tuple_at(const void *p) {\n    return *(const typename volt_field<I, 0, T...>::type *)((const char *)p + volt_field<I, 0, T...>::at);\n}\n#endif\n#if __cplusplus >= 201703L\n// a variant-like made from the Volt enum it reads as: its u32 tag, then the variant's value where C\n// puts the union of them\ntemplate <class... A>\nstruct volt_max_align {\n    static const size_t v = 1;\n};\ntemplate <class F, class... A>\nstruct volt_max_align<F, A...> {\n    static const size_t v = alignof(F) > volt_max_align<A...>::v ? alignof(F) : volt_max_align<A...>::v;\n};\ntemplate <class X, size_t I, size_t Off, class... A>\nstruct volt_alt_in {\n    static X make(const char *, uint32_t) { volt_cpp_throw(\"a Volt enum's tag names no variant\"); }\n};\ntemplate <class X, size_t I, size_t Off, class F, class... A>\nstruct volt_alt_in<X, I, Off, F, A...> {\n    static X make(const char *p, uint32_t tag) {\n        if (tag == I) {\n            return X(std::in_place_index<I>, *(const F *)(p + Off));\n        }\n        return volt_alt_in<X, I + 1, Off, A...>::make(p, tag);\n    }\n};\ntemplate <class X, class... A>\nstatic X volt_variant_in(const void *p) {\n    const size_t al = volt_max_align<A...>::v;\n    return volt_alt_in<X, 0, (sizeof(uint32_t) + al - 1) / al * al, A...>::make((const char *)p, *(const uint32_t *)p);\n}\n#endif\n\n// a reference result: the address of what it refers to (operator& or not), for a borrowed handle\ntemplate <class T>\nstatic void *volt_cpp_addr(const T &r) {\n    return (void *)&reinterpret_cast<const volatile char &>(r);\n}\n\n// a T* parameter from a Volt H* (null, or the handle's object)\ntemplate <class T>\nstatic T *volt_cpp_ptr(void *h) {\n    return h ? (T *)((volt_handle *)h)->cpp : 0;\n}\n\n#if __cplusplus >= 201103L\ntemplate <class T>\nstatic T *volt_cpp_clone(T *p, std::true_type) {\n    return new T(*p);\n}\n\ntemplate <class T>\nstatic T *volt_cpp_clone(T *, std::false_type) {\n    std::fprintf(stderr, \"panic: a borrowed C++ object handed over to be owned, and it can't be copied\\n\");\n    std::exit(101);\n}\n\n// a std::unique_ptr parameter's object: the handle's, which it no longer owns (its delete does\n// nothing), or a copy of a borrowed one's\ntemplate <class T, bool C>\nstatic T *volt_cpp_release(void *h) {\n    volt_handle *v = (volt_handle *)h;\n    T *p = &volt_cpp_obj<T>(v->cpp);\n    if (v->borrowed) {\n        return volt_cpp_clone(p, std::integral_constant<bool, C>());\n    }\n    v->cpp = 0;\n    return p;\n}\n#endif\n";

// a C++ unit of the program: the headers of the imports compiled under its standard, and a wrapper
// for each C++ call they make (empty when they make none)
attach fn cpp_unit(this: checker&, unit: u32, live: std::map<u32, bool>&) -> std::string {
    var out: std::string = {};
    // only the wrappers the program reaches (one compiled for an import's fn nothing calls can
    // need a library the program doesn't link: re2's LazyRE2::get needs abseil's)
    var keep: std::vec<bool> = {};
    var any = false;
    for (j) in 0..this.cpp_shims.len {
        val k = *this.cpp_shim_unit.at(j) == unit && live.get(*this.cpp_shim_fns.at(j)) != null;
        put(&keep, k);
        any = any || k;
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
            if (*keep.at(j) && contains(this.cpp_shims.at(j).as_str(), this.cpp_decl_names.at(i).as_str())) {
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
        if (*keep.at(j)) {
            out.append(this.cpp_shims.at(j).as_str());
            out.push('\n');
        }
    }
    out.append("}\n");
    return out;
}
