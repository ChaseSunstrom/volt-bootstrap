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
// function that can throw also gets a try_ form that returns cpp_error::EXCEPTION instead (its
// message: last_exception()). What doesn't map is left out with a comment.
use { "clang-c/Index.h" } as clang;
use std::mem;

// what clang says of an imported class (see probe)
struct cpp_traits {
    trivial: bool = false;      // trivially copyable: Volt holds it by value, else by handle
    destructible: bool = false; // its destructor can be called from outside, so Volt can own one
    copyable: bool = false;     // it can be made from a const& (it isn't abstract, its copy constructor is public)
    defaults: bool = false;     // it can be made from nothing (T::new() when it declares no constructor)
    assignable: bool = false;   // it can be assigned from an rvalue (a field of it gets a set_)
}

// the Volt source being written for one import: the classes, enums and class templates it declares
// (C++ qualified name -> Volt path inside the import's namespace), so types can refer to them
struct cpp_gen {
    c: checker&;
    out: std::string = {};
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
}

// ---------- names ----------

fn in_system(c: clang::CXCursor) -> bool {
    return clang::clang_Location_isInSystemHeader(clang::clang_getCursorLocation(c)) != 0;
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
    return move out;
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
    return move out;
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
        val pt = clang::clang_getPointeeType(ct);
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
        return move inner;
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
    var out = S(*base);
    out.push('<');
    for (i) in 0..@cast<u32>(n) {
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
    return move out;
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
    return move q;
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
    return std_template(ct) != null;
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
        val st = std_template(base);
        if (st != null && (st ?? S("")).as_str() == "vector") {
            val ct = clang::clang_getCanonicalType(base);
            val elem = this.vtype(clang::clang_Type_getTemplateArgumentAsType(ct, 0), tparams) ?? return null;
            var vec = type_spelling(ct);
            if (starts_with(vec.as_str(), "const ")) {
                vec = S(vec.as_str()[6..vec.len()]);
            }
            return { vty: fmt("{}[..]", move elem), pass: S(name), cpp: fmt4("{}({}.ptr, {}.ptr + {}.len)", move vec, copy slot, copy slot, copy slot) };
        }
    }
    // a class Volt holds by handle: its object, by reference (const& or &); by value or && C++ moves
    // from it, and the Volt value still deletes what's left
    val hc = this.handle_of(base);
    if (hc) {
        val vt = this.vtype(base, tparams) ?? return null;
        val obj = fmt2("volt_cpp_obj<{}>({})", copy hc, copy slot);
        if (k == clang::CXType_LValueReference) {
            return { vty: fmt("{}&", move vt), pass: fmt("{}.cpp", S(name)), cpp: move obj };
        }
        return { vty: move vt, pass: fmt("{}.cpp", S(name)), cpp: fmt("std::move({})", move obj) };
    }
    if (k == clang::CXType_RValueReference) {
        // T&&: Volt hands the value over (a class by its place), C++ moves from it
        val pt = clang::clang_getPointeeType(t);
        for (p&) in tparams.items() {
            if (strip_const(type_spelling(pt).as_str()) == *p) {
                return { vty: S(*p), pass: fmt("&{}", S(name)), cpp: fmt("std::move({})", move slot) };
            }
        }
        val inner = this.vtype(pt, tparams) ?? return null;
        if (is_class(pt)) {
            return { vty: move inner, pass: fmt("&{}", S(name)), cpp: fmt("std::move({})", move slot) };
        }
        return { vty: move inner, pass: S(name), cpp: fmt("std::move({})", move slot) };
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
        return { vty: move v, pass: fmt("&{}", S(name)), cpp: fmt("std::move({})", move slot) };
    }
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_Enum) {
        return { vty: move v, pass: S(name), cpp: fmt2("({})({})", cpp_qual(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(t))), move slot) };
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
}

// the Volt return type of a C++ one (a reference to a class stays one; to a const number, a copy)
attach fn result(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> cpp_ret? {
    if (t.kind == clang::CXType_RValueReference) {
        return null;
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
        val st = std_template(base);
        if (st != null && (st ?? S("")).as_str() == "vector") {
            val elem = this.vtype(clang::clang_Type_getTemplateArgumentAsType(clang::clang_getCanonicalType(base), 0), tparams) ?? return null;
            return { vty: fmt("std::vec<{}>", copy elem), way: ret_way::VECTOR, elem: move elem };
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
    val binary: str[29] = { "+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "&&", "||", "[]", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=" };
    val names: str[29] = { "op_add", "op_sub", "op_mul", "op_div", "op_rem", "op_eq", "op_ne", "op_lt", "op_le", "op_gt", "op_ge", "op_bitand", "op_bitor", "op_xor", "op_shl", "op_shr", "op_and", "op_or", "op_index", "op_add_assign", "op_sub_assign", "op_mul_assign", "op_div_assign", "op_rem_assign", "op_bitand_assign", "op_bitor_assign", "op_xor_assign", "op_shl_assign", "op_shr_assign" };
    for (i) in 0..29 {
        if (sym == binary[i]) {
            return names[i];
        }
    }
    return null;
}

// how many parameters a function cursor has
fn param_count(c: clang::CXCursor) -> usize {
    var n: usize = 0;
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_ParmDecl) {
            n += 1;
        }
    }
    return n;
}

// ---------- functions ----------

// one Volt fn per way to call a C++ function or method: `head` is the Volt signature up to its
// params (`attach fn area(this: Shape&` or `fn add(`), `call` the C++ expression up to its args
// (`{0}.area(` or `geo::add(`); `first` is the @cpp index of the first C++ argument; self_arg is
// what the Volt fn passes first (this), if anything. A default argument adds an overload without
// it, and one that can throw a try_ form too
attach fn callable(this: cpp_gen&, generics: str, head: str, has_params: bool, fn_cursor: clang::CXCursor, ret: cpp_ret?, call: str, self_arg: str?, extra: str, tparams: std::vec<str>&, what: str) -> void {
    var r: cpp_ret = { vty: S("void") };
    if (ret) {
        r = copy ret;
    } else {
        this.line(fmt("// left out: {} (its return type)", S(what)).as_str());
        return;
    }
    // the parameters (children, which templates have too; clang_Cursor_getArgument doesn't)
    var parms: std::vec<clang::CXCursor> = {};
    for (ch&) in children(fn_cursor).items() {
        if (clang::clang_getCursorKind(*ch) == clang::CXCursor_ParmDecl) {
            put(&parms, *ch);
        }
    }
    var args: std::vec<cpp_arg> = {};
    var names: std::vec<std::string> = {};
    var optional: usize = 0;
    var first: usize = 0;
    if (self_arg != null) {
        first = 1;
    }
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
            this.line(fmt2("// left out: {} (parameter {}'s type)", S(what), copy name).as_str());
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
            n_passed = 1;
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
    if (generics.len > 0) {
        this.line(generics);
    }
    this.line(fmt("{} {{", S(sig)).as_str());
    this.depth += 1;
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
        .HANDLE => { this.line(fmt4("return {{ cpp: @cpp<void*{}>(\"new {}({})\"{}) }};", S(extra), copy r.cls, S(cpp), S(tail)).as_str()); },
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
            this.line("return move try_vec;");
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
    this.line("return move try_text;");
}

// the try_ form of a call: cpp_error::EXCEPTION when it throws (last_exception() says what)
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
        lambda = fmt3("{} = static_cast<std::remove_reference_t<decltype({})>>({})", copy slot, copy slot, move conv);
        if (all_tail.len() == 0) {
            all_tail = S(", &try_out");
        } else {
            all_tail.append(", &try_out");
        }
    }
    this.line(fmt3("if (!@cpp<bool{}>(\"VOLT_CPP_CATCH({})\"{})) {{", S(extra), move lambda, move all_tail).as_str());
    this.line("    return cpp_error::EXCEPTION;");
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
fn template_params(c: clang::CXCursor) -> std::vec<std::string>? {
    var out: std::vec<std::string> = {};
    for (ch&) in children(c).items() {
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_TemplateTypeParameter) {
            put(&out, cursor_name(*ch));
        } else if (k == clang::CXCursor_NonTypeTemplateParameter || k == clang::CXCursor_TemplateTemplateParameter) {
            return null;
        }
    }
    return move out;
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
    return move s;
}

// ", T, U": the extra @cpp type arguments a template's {t0}, {t1} stand for
fn extra_types(ps: std::vec<std::string>&) -> std::string {
    var s: std::string = {};
    for (p&) in ps.items() {
        s.append(", ");
        s.append(p.as_str());
    }
    return move s;
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
    return move s;
}

fn str_views(v: std::vec<std::string>&) -> std::vec<str> {
    var out: std::vec<str> = {};
    for (s&) in v.items() {
        put(&out, s.as_str());
    }
    return move out;
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
    val vn = vname(name.as_str());
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
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) != clang::CXCursor_CXXMethod || !is_public(*ch) || clang::clang_CXXMethod_isDeleted(*ch) != 0) {
            continue;
        }
        val mn = cursor_name(*ch);
        val is_static = clang::clang_CXXMethod_isStatic(*ch) != 0;
        var vn_m = vname(mn.as_str());
        if (starts_with(mn.as_str(), "operator")) {
            if (is_static) {
                continue;
            }
            vn_m = S(op_name(mn.as_str(), param_count(*ch) + 1) ?? continue);
        }
        val ret = this.result(clang::clang_getCursorResultType(*ch), &tp);
        val what = fmt2("{}::{}", copy q, copy mn);
        if (is_static) {
            val head = fmt2("attach fn {}(static this: {}", copy vn_m, copy self_ty);
            val call = fmt2("{}::{}(", copy cpp_self, copy mn);
            this.callable(gen.as_str(), head.as_str(), true, *ch, ret, call.as_str(), null, extra.as_str(), &tp, what.as_str());
        } else {
            val head = fmt2("attach fn {}(this: {}&", copy vn_m, copy self_ty);
            val call = fmt("{0}.{}(", copy mn);
            this.callable(gen.as_str(), head.as_str(), true, *ch, ret, call.as_str(), "this", extra.as_str(), &tp, what.as_str());
        }
    }
}

// a class that isn't trivially copyable: a handle to an object C++ allocates, so a Volt move moves
// only the pointer and the object never changes place (it may point into itself, as libstdc++'s
// std::string does)
attach fn handle_class(this: cpp_gen&, c: clang::CXCursor, vn: str, q: str) -> void {
    this.line(fmt("// C++'s {}: it isn't trivially copyable, so Volt holds it by handle (C++ allocates it)", S(q)).as_str());
    this.line(fmt("struct {} {{", S(vn)).as_str());
    this.line("    cpp: void* = null; // the C++ object (null when there's none, as in one made with {})");
    this.line("}");
    // the object, in a C++ expression (an empty handle stops the program)
    val obj = fmt("volt_cpp_obj<{}>({{0}})", S(q));
    val none: std::vec<str> = {};
    val abstract_ = clang::clang_CXXRecord_isAbstract(c) != 0;
    val tr = *(this.traits.get(q) ?? return);
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
    this.line("    if (this.cpp != null) {");
    this.line(fmt("        @cpp<void>(\"delete ({} *){{0}}\", this.cpp);", S(q)).as_str());
    this.line("    }");
    this.line("}");
    if (tr.copyable) {
        this.line(fmt2("attach fn copy(this: {}&) -> {} {{", S(vn), S(vn)).as_str());
        this.line("    if (this.cpp == null) {");
        this.line("        return {};");
        this.line("    }");
        this.line(fmt2("    return {{ cpp: @cpp<void*>(\"new {}(*({} *){{0}})\", this.cpp) }};", S(q), S(q)).as_str());
        this.line("}");
    }
    // the methods before the fields' getters and set_ methods, so a method of the same signature
    // (a set_x of its own) is the one Volt calls
    this.class_methods(c, vn, q, obj.as_str());
    for (f&) in children(c).items() {
        if (clang::clang_getCursorKind(*f) != clang::CXCursor_FieldDecl || !is_public(*f) || clang::clang_Cursor_isBitField(*f) != 0) {
            continue;
        }
        val ft = clang::clang_getCursorType(*f);
        if (ft.kind == clang::CXType_LValueReference || ft.kind == clang::CXType_RValueReference) {
            continue;
        }
        val fv = vname(cursor_name(*f).as_str());
        val at = fmt2("{}.{}", copy obj, cursor_name(*f));
        var r = this.result(ft, &none) ?? continue;
        // a field held by handle comes back as a copy of it
        var getter = true;
        val fh = this.handle_of(ft);
        if (fh) {
            getter = (this.traits.get(fh.as_str()) ?? continue)->copyable;
        }
        if (getter && this.first_time(fmt2("attach fn {}(this: {}&", copy fv, S(vn)).as_str(), "")) {
            this.fn_text("", fmt3("attach fn {}(this: {}&) -> {}", copy fv, S(vn), copy r.vty).as_str(), &r, at.as_str(), ", this.cpp", "");
        }
        if (!this.assignable(ft)) {
            continue;
        }
        val a = this.param(ft, "v", 1, &none) ?? continue;
        if (this.first_time(fmt2("attach fn set_{}(this: {}&", copy fv, S(vn)).as_str(), fmt(",{}", copy a.vty).as_str())) {
            this.line(fmt3("attach fn set_{}(this: {}&, v: {}) -> void {{", copy fv, S(vn), copy a.vty).as_str());
            this.line(fmt3("    @cpp<void>(\"{} = {}\", this.cpp, {});", copy at, copy a.cpp, copy a.pass).as_str());
            this.line("}");
        }
    }
}

// the public methods of a class held by handle (obj: the object, in a C++ expression)
attach fn class_methods(this: cpp_gen&, c: clang::CXCursor, vn: str, q: str, obj: str) -> void {
    val none: std::vec<str> = {};
    for (ch&) in children(c).items() {
        if (clang::clang_getCursorKind(*ch) != clang::CXCursor_CXXMethod || !is_public(*ch) || clang::clang_CXXMethod_isDeleted(*ch) != 0) {
            continue;
        }
        val mn = cursor_name(*ch);
        val is_static = clang::clang_CXXMethod_isStatic(*ch) != 0;
        var vn_m = vname(mn.as_str());
        if (starts_with(mn.as_str(), "operator")) {
            if (is_static) {
                continue;
            }
            vn_m = S(op_name(mn.as_str(), param_count(*ch) + 1) ?? continue);
        }
        val ret = this.result(clang::clang_getCursorResultType(*ch), &none);
        val what = fmt2("{}::{}", S(q), copy mn);
        if (is_static) {
            this.callable("", fmt2("attach fn {}(static this: {}", copy vn_m, S(vn)).as_str(), true, *ch, ret, fmt2("{}::{}(", S(q), copy mn).as_str(), null, "", &none, what.as_str());
        } else {
            this.callable("", fmt2("attach fn {}(this: {}&", copy vn_m, S(vn)).as_str(), true, *ch, ret, fmt2("{}.{}(", S(obj), copy mn).as_str(), "this.cpp", "", &none, what.as_str());
        }
    }
}

// what clang says of each class, from a second parse of the same headers with these appended:
//     constexpr bool t0 = __is_trivially_copyable(::geo::Shape); (d0, c0, a0, n0 likewise)
// A class it can't answer for is held by handle, and Volt neither makes, copies nor assigns one.
// ponytail: the second parse reads every header again (<string>, <vector>: about twice the
// import's time); a precompiled preamble with clang_reparseTranslationUnit if that ever matters
attach fn probe(this: cpp_gen&, src: str, args: std::vec<str>&) -> void {
    var names: std::vec<str> = {};
    var text = S(src);
    text.append("namespace volt_probe {\n");
    for (e) in this.classes.iter() {
        val i = unum(@cast<u64>(names.len));
        val q = S(*e.key);
        text.append(fmt2("constexpr bool t{} = __is_trivially_copyable(::{});\n", copy i, copy q).as_str());
        text.append(fmt2("constexpr bool d{} = __is_destructible(::{});\n", copy i, copy q).as_str());
        text.append(fmt3("constexpr bool c{} = __is_constructible(::{}, const ::{} &);\n", copy i, copy q, copy q).as_str());
        text.append(fmt3("constexpr bool a{} = __is_assignable(::{} &, ::{} &&);\n", copy i, copy q, copy q).as_str());
        text.append(fmt2("constexpr bool n{} = __is_constructible(::{});\n", copy i, copy q).as_str());
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
            } else {
                tr->defaults = yes;
            }
        }
    }
}

// ---------- enums ----------

attach fn enum_decl(this: cpp_gen&, c: clang::CXCursor) -> void {
    val name = cursor_name(c);
    if (name.len() == 0) {
        return;
    }
    val none: std::vec<str> = {};
    val tag = this.vtype(clang::clang_getEnumDeclIntegerType(c), &none) ?? S("i32");
    val vn = vname(name.as_str());
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
    // an unscoped enum's names are in the enclosing namespace too
    if (clang::clang_EnumDecl_isScoped(c) == 0) {
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
        if (in_system(*ch)) {
            continue;
        }
        val k = clang::clang_getCursorKind(*ch);
        val name = cursor_name(*ch);
        if (name.len() == 0) {
            continue;
        }
        var p = S(vpath);
        p.append(vname(name.as_str()).as_str());
        val q = this.c.intern(cpp_qual(*ch));
        if (k == clang::CXCursor_Namespace) {
            p.append("::");
            this.scan(*ch, p.as_str());
        } else if ((k == clang::CXCursor_ClassDecl || k == clang::CXCursor_StructDecl) && clang::clang_isCursorDefinition(*ch) != 0) {
            this.classes.put(q, this.c.intern(move p));
        } else if (k == clang::CXCursor_ClassTemplate) {
            this.templates.put(q, this.c.intern(move p));
        } else if (k == clang::CXCursor_EnumDecl) {
            this.enums.put(q, this.c.intern(move p));
        }
    }
}

// the Volt source for the declarations under c
attach fn emit(this: cpp_gen&, c: clang::CXCursor) -> void {
    for (ch&) in children(c).items() {
        if (in_system(*ch)) {
            continue;
        }
        val k = clang::clang_getCursorKind(*ch);
        if (k == clang::CXCursor_Namespace) {
            val name = cursor_name(*ch);
            if (name.len() == 0) {
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
        } else if (k == clang::CXCursor_ClassTemplate) {
            val tps = template_params(*ch);
            if (tps) {
                this.class(*ch, copy tps);
            }
        } else if (k == clang::CXCursor_EnumDecl) {
            this.enum_decl(*ch);
        } else if (k == clang::CXCursor_FunctionDecl) {
            val none: std::vec<std::string> = {};
            this.free_fn(*ch, &none);
        } else if (k == clang::CXCursor_FunctionTemplate) {
            val tps = template_params(*ch);
            if (tps) {
                this.free_fn(*ch, &tps);
            }
        }
    }
}

// the declarations the generated code relies on: stdcxx's smart pointers, and what a try_ form
// returns
attach fn std_extras(this: cpp_gen&) -> void {
    if (this.unique || this.shared) {
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
    if (this.unique || this.shared) {
        this.depth -= 1;
        this.line("}");
    }
    if (this.tries) {
        this.line("// what a try_ form returns when the C++ code threw");
        this.line("error cpp_error {");
        this.line("    EXCEPTION,");
        this.line("}");
        this.line("// what the exception a try_ form caught last (on this thread) said");
        this.line("fn last_exception() -> std::string {");
        this.depth += 1;
        this.line("val r = @cpp<str>(\"volt_cpp_dup(volt_cpp_last)\");");
        this.text_out("r");
        this.depth -= 1;
        this.line("}");
    }
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

attach fn import_cpp(this: checker&, headers: std::vec<std::string>&, alias: str, ns: u32, span: span) -> compile_error!void {
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
        for (x&) in this.cpp_includes.items() {
            if (*x == line.as_str()) {
                have = true;
            }
        }
        if (!have) {
            put(&this.cpp_includes, this.intern(move line));
        }
    }
    var args: std::vec<str> = {};
    put(&args, "-x");
    put(&args, "c++");
    put(&args, "-std=c++17");
    for (f&) in this.opts.pp_flags.items() {
        put(&args, *f);
    }
    var tu = clang_parse("volt_cpp_import.cpp", src.as_str(), &args);
    val bad = tu.first_error();
    if (bad) {
        return fail(span, fmt("libclang couldn't read these C++ headers: {}", copy bad));
    }
    var g: cpp_gen = { c: this };
    g.scan(tu.root(), "");
    g.probe(src.as_str(), &args);
    g.out.append(fmt("// the Volt side of use cpp {{ ... }} as {} (generated by voltc from the headers)\n", S(alias)).as_str());
    g.emit(tu.root());
    g.std_extras();
    // it's Volt source like any other: lexed, parsed and declared in namespace `alias`
    var fname = S("<use cpp as ");
    fname.append(alias);
    fname.push('>');
    // VOLT_SHOW_CPP=1 prints it: what the headers became
    if (std::process::env("VOLT_SHOW_CPP") != null) {
        std::eprint("{}", g.out);
    }
    put(&this.c_texts, copy g.out);
    val text = this.c_texts.at(this.c_texts.len - 1).as_str();
    put(this.files, { name: this.intern(move fname), text: text });
    val file = @cast<u32>(this.files.len - 1);
    val toks = try lex(text, file);
    var names: std::map<str, bool> = {};
    collect_generic_names(&toks, &names);
    var p: parser = { src: text, toks: &toks, pos: 0, generics: &names };
    val items = try p.parse_file();
    put(&this.cpp_items, bx(move items));
    val n = this.ns_child(ns, alias);
    return this.collect(*this.cpp_items.at(this.cpp_items.len - 1), n);
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
            return move s;
        },
        .REF(x) => {
            var s = this.cpp_spell(x) ?? return null;
            s.append(" *");
            return move s;
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
                return move out;
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
// spelling of the Nth type after R. Each distinct call becomes an extern "C" wrapper function in the
// program's C++ file (cpp_unit): a C++ class comes back through a pointer to the result's place,
// a reference as a pointer, anything else by value
attach fn cpp_call(this: checker&, gargs: std::vec<garg>&, args: std::vec<garg>&, span: span) -> compile_error!tval {
    if (gargs.len == 0 || args.len == 0) {
        return fails(span, "@cpp<R>(\"C++ expression\", args...)");
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
    var params: std::string = {};
    var ptys: std::vec<u32> = {};
    var vals: std::vec<u32> = {};
    var subst: std::vec<std::string> = {};
    if (class_ret) {
        params.append((this.cpp_spell(r) ?? S("void")).as_str());
        params.append(" *ret");
        put(&ptys, this.t.intern(tyk::PTR(r)));
    }
    for (i) in 1..args.len {
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
            val hole = tx[k + 1..e];
            var done = false;
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
            .REF(x) => { body = fmt("return &({});", move expr); },
            default => { body = fmt2("return ({})({});", copy rsp, move expr); },
        }
    }
    // one wrapper per distinct call
    val key = fmt3("{}({}){}", copy rsp, copy params, copy body);
    var idx: u32 = 0;
    val have = this.cpp_shim_keys.get(key.as_str());
    if (have) {
        idx = *have;
    } else {
        idx = @cast<u32>(this.cpp_shims.len);
        var name = S("volt_cpp_");
        name.append_uint(@cast<u64>(idx));
        var w = fmt3("{} {}({}) {{\n", copy rsp, copy name, copy params);
        w.append(fmt("    try {{\n        {}\n    }} catch (const std::exception &e) {{\n        volt_cpp_throw(e.what());\n    }} catch (...) {{\n        volt_cpp_throw(\"an exception that isn't a std::exception\");\n    }}\n}}\n", copy body).as_str());
        put(&this.cpp_shims, move w);
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

// the program's C++ file: the imported headers and a wrapper for each C++ call (empty when it has none)
attach fn cpp_unit(this: checker&) -> std::string {
    var out: std::string = {};
    if (this.cpp_shims.len == 0) {
        return move out;
    }
    out.append("// generated by voltc: the C++ this program calls (use cpp); each function wraps one call\n");
    out.append("#include <algorithm>\n#include <cstddef>\n#include <cstdint>\n#include <cstdio>\n#include <cstdlib>\n#include <cstring>\n#include <exception>\n#include <memory>\n#include <new>\n#include <string>\n#include <string_view>\n#include <type_traits>\n#include <utility>\n#include <vector>\n");
    for (inc&) in this.cpp_includes.items() {
        out.append(*inc);
        out.push('\n');
    }
    out.append("\n// an exception that reaches Volt stops the program, like a panic\n");
    out.append("[[noreturn]] static void volt_cpp_throw(const char *what) {\n    std::fprintf(stderr, \"panic: C++ exception: %s\\n\", what);\n    std::exit(101);\n}\n");
    out.append("\n// the object behind a handle (Volt holds a class that isn't trivially copyable by pointer)\ntemplate <class T>\nstatic T &volt_cpp_obj(void *p) {\n    if (!p) {\n        std::fprintf(stderr, \"panic: a C++ object Volt holds by handle was never made (its handle is empty)\\n\");\n        std::exit(101);\n    }\n    return *(T *)p;\n}\n");
    out.append("\n// Volt's str and T[..]\nstruct volt_str {\n    const unsigned char *ptr;\n    size_t len;\n};\n\ntemplate <class T>\nstruct volt_slice {\n    T *ptr;\n    size_t len;\n};\n");
    out.append("\n// text copied out of C++, in memory the Volt side frees (std::free); and a view's bytes\nstatic inline volt_str volt_cpp_dup(std::string_view s) {\n    unsigned char *p = (unsigned char *)std::malloc(s.size() ? s.size() : 1);\n    if (!p) {\n        volt_cpp_throw(\"out of memory\");\n    }\n    std::memcpy(p, s.data(), s.size());\n    return {p, s.size()};\n}\n\nstatic inline volt_str volt_cpp_view(std::string_view s) {\n    return {(const unsigned char *)s.data(), s.size()};\n}\n");
    out.append("\n// a std::vector's elements copied out the same way\ntemplate <class T>\nstatic volt_slice<T> volt_cpp_dup_vec(const std::vector<T> &v) {\n    static_assert(std::is_trivially_copyable<T>::value, \"Volt copies out a std::vector of plain values\");\n    T *p = (T *)std::malloc(sizeof(T) * (v.size() ? v.size() : 1));\n    if (!p) {\n        volt_cpp_throw(\"out of memory\");\n    }\n    std::copy(v.begin(), v.end(), p);\n    return {p, v.size()};\n}\n");
    out.append("\n// try_ forms: run the call, and keep what an exception says instead of stopping\nstatic thread_local std::string volt_cpp_last;\n\ntemplate <class F>\nstatic bool volt_cpp_catch(F f) {\n    try {\n        f();\n        return true;\n    } catch (const std::exception &e) {\n        volt_cpp_last = e.what();\n    } catch (...) {\n        volt_cpp_last = \"an exception that isn't a std::exception\";\n    }\n    return false;\n}\n\n#define VOLT_CPP_CATCH(...) volt_cpp_catch([&]() { __VA_ARGS__; })\n\nextern \"C\" {\n\n");
    for (w&) in this.cpp_shims.items() {
        out.append(w.as_str());
        out.push('\n');
    }
    out.append("}\n");
    return move out;
}
