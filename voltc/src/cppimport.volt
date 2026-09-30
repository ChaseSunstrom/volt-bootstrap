// C++ import: `use cpp { "shapes.hpp" } as shapes;` reads C++ headers with libclang and turns what
// Volt can use into Volt source, declared in namespace `shapes`:
//   namespaces      -> namespaces
//   classes         -> structs with C++'s layout: public fields where C++ puts them, the rest padding
//   constructors    -> T::new(...) (static attach fns); a class without any gets T::new()
//   destructor      -> delete; copy constructor -> copy (only for classes that need them)
//   methods         -> attach fns (static ones take `static this`); overloads stay overloads, and a
//                      default argument gives an overload without it
//   free functions  -> fns; function and class templates -> generic fns and structs
//   enums           -> enums with the same tag type and values (an unscoped one's names are also
//                      constants next to it)
// Every body is one @cpp<R>("C++ expression", args) (calls.volt): the checker turns each call it
// instantiates into an extern "C" wrapper function in a C++ file compiled with $CXX and linked in,
// so both backends call C++ the same way. A C++ exception that reaches one stops the program.
// What doesn't map (rvalue references, std types, operators...) is left out with a comment.
use { "clang-c/Index.h" } as clang;
use std::mem;

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
        val a = this.vtype(clang::clang_Type_getTemplateArgumentAsType(ct, i), tparams) ?? return null;
        out.append(a.as_str());
    }
    out.push('>');
    return move out;
}

fn is_class(t: clang::CXType) -> bool {
    return clang::clang_getCanonicalType(t).kind == clang::CXType_Record;
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
    if (k == clang::CXType_RValueReference) {
        return null;
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
        return { vty: move v, pass: fmt("&{}", S(name)), cpp: move slot };
    }
    if (clang::clang_getCanonicalType(t).kind == clang::CXType_Enum) {
        return { vty: move v, pass: S(name), cpp: fmt2("({})({})", cpp_qual(clang::clang_getTypeDeclaration(clang::clang_getCanonicalType(t))), move slot) };
    }
    return { vty: move v, pass: S(name), cpp: move slot };
}

// the Volt return type of a C++ one (a reference to a class stays one; to a const number, a copy)
attach fn result(this: cpp_gen&, t: clang::CXType, tparams: std::vec<str>&) -> std::string? {
    if (t.kind == clang::CXType_RValueReference) {
        return null;
    }
    if (t.kind == clang::CXType_LValueReference) {
        val pt = clang::clang_getPointeeType(t);
        var inner = this.vtype(pt, tparams) ?? return null;
        if (is_class(pt) || clang::clang_isConstQualifiedType(pt) == 0) {
            inner.push('&');
        }
        return move inner;
    }
    return this.vtype(t, tparams);
}

// ---------- functions ----------

// one Volt fn per way to call a C++ function or method: `head` is the Volt signature up to its
// params (`attach fn area(this: Shape&` or `fn add(`), `call` the C++ expression up to its args
// (`{0}.area(` or `geo::add(`); `first` is the @cpp index of the first C++ argument; self_arg is
// what the Volt fn passes first (this), if anything. A default argument adds an overload without it
attach fn callable(this: cpp_gen&, generics: str, head: str, has_params: bool, fn_cursor: clang::CXCursor, ret: std::string?, call: str, self_arg: str?, extra: str, tparams: std::vec<str>&, what: str) -> void {
    var r = S("void");
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
    // every count of trailing default arguments, most first
    var drop: usize = 0;
    while (drop <= optional) {
        val count = args.len - drop;
        var sig = S(head);
        var call_args: std::string = {};
        var passed: std::string = {};
        if (self_arg) {
            passed.append(self_arg);
        }
        for (i) in 0..count {
            if (i > 0 || has_params) {
                sig.append(", ");
            }
            sig.append(fmt2("{}: {}", copy *names.at(i), copy args.at(i).vty).as_str());
            if (i > 0) {
                call_args.append(", ");
            }
            call_args.append(args.at(i).cpp.as_str());
            if (passed.len() > 0) {
                passed.append(", ");
            }
            passed.append(args.at(i).pass.as_str());
        }
        sig.append(") -> ");
        sig.append(r.as_str());
        var key = copy this.scope;
        key.push('|');
        key.append(head);
        for (i) in 0..count {
            key.push(',');
            key.append(args.at(i).vty.as_str());
        }
        if (this.written.get(key.as_str()) != null) {
            drop += 1;
            continue;
        }
        this.written.put(this.c.intern(move key), true);
        sig.append(" {");
        if (generics.len > 0) {
            this.line(generics);
        }
        this.line(sig.as_str());
        this.depth += 1;
        var body: std::string = {};
        if (r.as_str() != "void") {
            body.append("return ");
        }
        body.append(fmt3("@cpp<{}{}>(\"{}", copy r, S(extra), S(call)).as_str());
        body.append(call_args.as_str());
        body.append(")\"");
        if (passed.len() > 0) {
            body.append(", ");
            body.append(passed.as_str());
        }
        body.append(");");
        this.line(body.as_str());
        this.depth -= 1;
        this.line("}");
        drop += 1;
    }
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
    val name = cursor_name(c);
    if (starts_with(name.as_str(), "operator") || clang::clang_CXXMethod_isDeleted(c) != 0) {
        return;
    }
    val tp = str_views(tps);
    var call = cpp_qual(c);
    if (tps.len > 0) {
        call = cpp_template_ref(call.as_str(), tps.len);
    }
    call.push('(');
    val head = fmt("fn {}(", vname(name.as_str()));
    val ret = this.result(clang::clang_getCursorResultType(c), &tp);
    this.callable(generics_text(tps).as_str(), head.as_str(), false, c, move ret, call.as_str(), null, extra_types(tps).as_str(), &tp, name.as_str());
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
                val vt = this.vtype(clang::clang_getCursorType(*ch), &tp);
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
            this.callable(gen.as_str(), head.as_str(), true, *ch, copy self_ty, call.as_str(), null, extra.as_str(), &tp, fmt("{}'s constructor", copy q).as_str());
        }
    }
    if (!any_ctor && !abstract_) {
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
        if (starts_with(mn.as_str(), "operator")) {
            continue;
        }
        val ret = this.result(clang::clang_getCursorResultType(*ch), &tp);
        val what = fmt2("{}::{}", copy q, copy mn);
        if (clang::clang_CXXMethod_isStatic(*ch) != 0) {
            val head = fmt2("attach fn {}(static this: {}", vname(mn.as_str()), copy self_ty);
            val call = fmt2("{}::{}(", copy cpp_self, copy mn);
            this.callable(gen.as_str(), head.as_str(), true, *ch, move ret, call.as_str(), null, extra.as_str(), &tp, what.as_str());
        } else {
            val head = fmt2("attach fn {}(this: {}&", vname(mn.as_str()), copy self_ty);
            val call = fmt("{0}.{}(", copy mn);
            this.callable(gen.as_str(), head.as_str(), true, *ch, move ret, call.as_str(), "this", extra.as_str(), &tp, what.as_str());
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
    g.out.append(fmt("// the Volt side of use cpp {{ ... }} as {} (generated by voltc from the headers)\n", S(alias)).as_str());
    g.emit(tu.root());
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
    out.append("#include <cstddef>\n#include <cstdint>\n#include <cstdio>\n#include <cstdlib>\n#include <exception>\n#include <new>\n");
    for (inc&) in this.cpp_includes.items() {
        out.append(*inc);
        out.push('\n');
    }
    out.append("\n// an exception that reaches Volt stops the program, like a panic\n");
    out.append("[[noreturn]] static void volt_cpp_throw(const char *what) {\n    std::fprintf(stderr, \"panic: C++ exception: %s\\n\", what);\n    std::exit(101);\n}\n\nextern \"C\" {\n\n");
    for (w&) in this.cpp_shims.items() {
        out.append(w.as_str());
        out.push('\n');
    }
    out.append("}\n");
    return move out;
}
