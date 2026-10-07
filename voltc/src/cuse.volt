// C calls made per use. A C header's function-like macros (MAX(a, b)) and its varargs functions
// taking or giving a long double or a _Complex have no Volt signature until a call gives their
// arguments' types: clang works the call out in C, with the import's headers (its result is the
// expression's type), and a static C function made for those argument types makes it. Volt calls
// that function as it does a header's own (cimport.volt's wrappers), on either backend.
use std::mem;

// what a C import's per-use calls need: what a probe of a call reads (its #include lines, its
// standard), where its C goes, and what mapping a probed type back takes
struct c_ctx {
    ns: u32;                         // the import's namespace
    src: std::string;                // its #include lines
    standard: str;
    keep: bool;                      // its C is in a unit of its standard's (kept), not Volt's own
    kept: u32;
    d: cdecls;
    names: std::map<str, str>;       // struct tag -> Volt name
    c_names: std::map<str, str>;     // struct tag -> C name
    enum_names: std::map<str, str>;
    enum_ints: std::map<str, str>;
    complex: std::vec<str>;          // the complex structs declared (cf32, cf64)
    cf32: str;
    cf64: str;
    made: std::map<str, u32> = {};   // a call (callee and arguments) -> its Volt fn
}

// how one argument of a per-use call reaches C
struct c_arg {
    ty: u32;          // the Volt fn's parameter type
    base: u32;        // the value's own type
    mode: u8;         // 0: by value; 1: a place C's call sees as itself (by its address); 2: the
                      // same for a place that can't change (const); 3: a literal, written as C's
    lit: std::string; // 3: the literal in C
}

// import imp's per-use names, declared in namespace n: each a stub fn that takes anything, whose
// calls c_dyn_call makes; and where its context's import is
attach fn c_per_use(this: checker&, imp: c_imported&, n: u32, keep: bool, kept: u32, span: span) -> compile_error!void {
    val k = imp.ctx ?? return;
    val x = this.c_ctxs.at(k);
    x.ns = n;
    x.keep = keep;
    x.kept = kept;
    for (name) in imp.per_use.items() {
        var args: std::vec<garg> = {};
        put(&args, garg::EXPR({ kind: expr_kind::STR(fmt("c:{}", S(name))), span: span }));
        var attrs: std::vec<expr> = {};
        put(&attrs, { kind: expr_kind::BUILTIN("cpp_call", {}, move args), span: span });
        val f: fn_decl = { name: name, spec: null, params: {}, c_varargs: true, ret: { kind: type_kind::RESOLVED(VOID), span: span }, body: { stmts: {}, span: span }, is_async: false, is_comptime: false, extern_abi: null, is_export: false, is_attach: false };
        put(&this.owned_items, bx<item>({ kind: item_kind::FN(f), span: span, attrs: move attrs, vis: vis::PUBLIC, generics: {} }));
        try this.collect_item(*this.owned_items.at(this.owned_items.len - 1), n, null);
    }
}

// the per-use context of namespace ns's C import
attach fn c_ctx_of(this: checker&, ns: u32) -> usize? {
    var at: u32? = ns;
    while (at) {
        val n = at;
        for (k) in 0..this.c_ctxs.len {
            if (this.c_ctxs.at(k).ns == n) {
                return k;
            }
        }
        at = this.ns(n).parent;
    }
    return null;
}

// a literal argument as C writes it (a string, an integer): passed as itself, so a macro sees what
// C would (sizeof "abc" is 4, #x is its text)
fn c_literal(e: expr&) -> std::string? {
    match (e.kind) {
        .STR(s) => {
            var out = S("\"");
            for (ch) in s.as_str() {
                if (ch == '"' || ch == '\\') {
                    out.push('\\');
                    out.push(ch);
                } else if (ch < ' ' || ch > '~') {
                    out.push('\\');
                    out.push('0' + (ch >> 6));
                    out.push('0' + ((ch >> 3) & 7));
                    out.push('0' + (ch & 7));
                } else {
                    out.push(ch);
                }
            }
            out.push('"');
            return out;
        },
        .INT(v) => { return unum(@cast<u64>(v)); },
        default => { return null; },
    }
}

// a call of per-use stub d (callee: the macro or function): the Volt fn made for these arguments,
// called. An argument that's a place passes by its address, so the macro sees the place itself
// (++x changes the Volt variable; one that can't change is const to C)
attach fn c_dyn_call(this: checker&, d: u32, callee: str, name: str, explicit: std::vec<garg>&, args: std::vec<expr>&, want: u32?, span: span) -> compile_error!tval {
    if (explicit.len > 0) {
        return fails(span, "a C macro or function takes no generic arguments");
    }
    val k = this.c_ctx_of(this.decls.at(@cast<usize>(d)).ns) ?? return fails(span, "this C name's import is gone");
    var cargs: std::vec<c_arg> = {};
    var nargs: std::vec<expr> = {};
    var pre: std::vec<tval?> = {};
    var key = fmt("{}(", S(callee));
    for (j) in 0..args.len {
        val a = args.at(j);
        val lit = c_literal(a);
        if (lit == null && needs_context(a)) {
            return fails(a.span, "C works this call out from its arguments' types: give this one a type (a typed val)");
        }
        var want_a: u32? = null;
        if (lit) {
            if (starts_with(lit.as_str(), "\"")) {
                want_a = CSTR; // (a C string to C)
            }
        }
        var v = try this.expr(a, want_a);
        var arg: c_arg = { ty: v.ty, base: v.ty, mode: 0, lit: S("") };
        if (lit) {
            arg.mode = 3;
            arg.lit = copy lit;
            put(&nargs, copy *a);
        } else if (v.lv) {
            arg.mode = 2;
            if (v.mutable) {
                arg.mode = 1;
                this.note_write(&v);
                this.note_mut(&v);
            }
            val addr: expr = { kind: expr_kind::UNARY(unop::ADDR, bx(copy *a)), span: a.span };
            v = try this.expr(&addr, null);
            arg.ty = v.ty;
            put(&nargs, addr);
        } else {
            put(&nargs, copy *a);
        }
        key.append_uint(@cast<u64>(arg.mode));
        key.push(':');
        key.append_uint(@cast<u64>(arg.base));
        key.append(arg.lit.as_str());
        key.push(',');
        put(&pre, v);
        put(&cargs, move arg);
    }
    var made: u32 = 0;
    val have = this.c_ctxs.at(k).made.get(key.as_str());
    if (have) {
        made = *have;
    } else {
        made = try this.c_instance(k, callee, &cargs, span);
        this.c_ctxs.at(k).made.put(this.intern(move key), made);
    }
    var cands: std::vec<u32> = {};
    put(&cands, made);
    var none: std::vec<garg> = {};
    return this.pick_call(name, &cands, null, null, &none, &pre, &nargs, want, span);
}

// a Volt type as C writes it, for a call's argument (a reference is a pointer); none for one C has
// no type for. A 64-bit integer is long long, or (alt) long: both are i64 to Volt, and a pointer to
// one has to be the one C's call takes
attach fn c_spell(this: checker&, k: usize, t: u32, alt: bool) -> std::string? {
    match (*this.t.get(t)) {
        .VOID => { return S("void"); },
        .BOOL => { return S("_Bool"); },
        .CSTR => { return S("const char *"); },
        .VOIDPTR => { return S("void *"); },
        .FLOAT(bits) => {
            if (bits == 32) {
                return S("float");
            }
            if (bits == 64) {
                return S("double");
            }
            return null;
        },
        .INT(i) => {
            match (i) {
                .I8 => { return S("signed char"); },
                .I16 => { return S("short"); },
                .I32 => { return S("int"); },
                .I64 => {
                    if (alt) {
                        return S("long");
                    }
                    return S("long long");
                },
                .I128 => { return S("__int128"); },
                .ISIZE => { return S("__PTRDIFF_TYPE__"); },
                .U8 => { return S("unsigned char"); },
                .U16 => { return S("unsigned short"); },
                .U32 => { return S("unsigned int"); },
                .U64 => {
                    if (alt) {
                        return S("unsigned long");
                    }
                    return S("unsigned long long");
                },
                .U128 => { return S("unsigned __int128"); },
                .USIZE => { return S("__SIZE_TYPE__"); },
            }
        },
        .REF(x) => {
            var s = this.c_spell(k, x, alt) ?? return null;
            s.append(" *");
            return s;
        },
        .PTR(x) => {
            var s = this.c_spell(k, x, alt) ?? return null;
            s.append(" *");
            return s;
        },
        .STRUCT(sid) => {
            // one of the import's structs: its C name
            val x = this.c_ctxs.at(k);
            var vn: str = "";
            match (this.item_of(this.si(sid).decl).kind) {
                .STRUCT(sd) => { vn = sd.name; },
                default => { return null; },
            }
            for (e) in x.names.iter() {
                if (*e.value == vn) {
                    return S(*(x.c_names.get(*e.key) ?? return null));
                }
            }
            return null;
        },
        .ENUM(eid) => {
            // a C enum passes as its integer
            if (!this.ei(eid).c_enum) {
                return null;
            }
            return this.c_spell(k, int_id(this.ei(eid).tag), alt);
        },
        default => { return null; },
    }
}

// a probed C type as the import's parser reads one (canonical: a typedef as what it names); none
// for one it doesn't name (an anonymous struct)
attach fn cx_ctype(this: checker&, t: clang::CXType, depth: u32) -> ctype? {
    val ct = clang::clang_getCanonicalType(t);
    val k = ct.kind;
    if (depth > 8) {
        return null;
    }
    if (k == clang::CXType_Void) {
        return ctype::VOID;
    }
    if (k == clang::CXType_Bool) {
        return ctype::BOOL;
    }
    if (k == clang::CXType_Char_S || k == clang::CXType_Char_U) {
        return ctype::CHAR;
    }
    if (k == clang::CXType_LongDouble) {
        return ctype::LDOUBLE;
    }
    if (k == clang::CXType_Float) {
        return ctype::PRIM("f32");
    }
    if (k == clang::CXType_Double) {
        return ctype::PRIM("f64");
    }
    if (k == clang::CXType_Complex) {
        val ek = clang::clang_getCanonicalType(clang::clang_getElementType(ct)).kind;
        if (ek == clang::CXType_Float) {
            return ctype::COMPLEX("float");
        }
        if (ek == clang::CXType_Double) {
            return ctype::COMPLEX("double");
        }
        if (ek == clang::CXType_LongDouble) {
            return ctype::COMPLEX("long double");
        }
        return null;
    }
    if (k == clang::CXType_Pointer) {
        val inner = this.cx_ctype(clang::clang_getPointeeType(ct), depth + 1) ?? return null;
        return ctype::PTR(bx(move inner));
    }
    // a string literal (#x): its chars, as C's call passes it on
    if (k == clang::CXType_ConstantArray) {
        val ek = clang::clang_getCanonicalType(clang::clang_getArrayElementType(ct)).kind;
        if (ek == clang::CXType_Char_S || ek == clang::CXType_Char_U) {
            return ctype::PTR(bx(ctype::CHAR));
        }
        return null;
    }
    if (k == clang::CXType_Record || k == clang::CXType_Enum) {
        val decl = clang::clang_getTypeDeclaration(ct);
        val tag = cursor_name(decl);
        if (tag.len() == 0 || clang::clang_Cursor_isAnonymous(decl) != 0) {
            return null;
        }
        if (k == clang::CXType_Enum) {
            return ctype::ENUM(this.intern(move tag));
        }
        return ctype::STRUCT(this.intern(move tag));
    }
    // an integer: by its size and sign
    val size = clang::clang_Type_getSizeOf(ct);
    val signed_ = k == clang::CXType_SChar || k == clang::CXType_Short || k == clang::CXType_Int || k == clang::CXType_Long || k == clang::CXType_LongLong || k == clang::CXType_Int128;
    val unsigned_ = k == clang::CXType_UChar || k == clang::CXType_UShort || k == clang::CXType_UInt || k == clang::CXType_ULong || k == clang::CXType_ULongLong || k == clang::CXType_UInt128;
    if (!signed_ && !unsigned_) {
        return null;
    }
    val ss: str[5] = { "i8", "i16", "i32", "i64", "i128" };
    val us: str[5] = { "u8", "u16", "u32", "u64", "u128" };
    var at: usize = 0;
    var n: i64 = 1;
    while (n < size && at < 4) {
        n *= 2;
        at += 1;
    }
    if (signed_) {
        return ctype::PRIM(ss[at]);
    }
    return ctype::PRIM(us[at]);
}

// import k's C (Volt's own, or its standard's unit)
attach fn c_put_text(this: checker&, k: usize, text: std::string) -> void {
    val x = this.c_ctxs.at(k);
    if (x.keep) {
        val t = this.c_unit_text.at(@cast<usize>(x.kept));
        t.append(text.as_str());
        t.push('\n');
        return;
    }
    put(&this.c_includes, this.intern(move text));
}

// the Volt fn calling callee with these arguments in import k: clang's type for the call
// (__typeof__ of it, in a probe of the import's headers), and a static C function making it. A
// pointer to a 64-bit integer is tried as long long, then as long
attach fn c_instance(this: checker&, k: usize, callee: str, cargs: std::vec<c_arg>&, span: span) -> compile_error!u32 {
    val x = this.c_ctxs.at(k);
    var copts: std::vec<str> = {};
    put(&copts, "-x");
    put(&copts, "c");
    put(&copts, this.intern(fmt("-std={}", S(x.standard))));
    put(&copts, "-Werror=incompatible-pointer-types");
    for (f&) in this.opts.pp_flags.items() {
        put(&copts, *f);
    }
    val main = "volt_c_call.c";
    var cts: std::vec<std::string> = {};
    var shown = S(""); // the call, as C types
    var rt: clang::CXType? = null;
    var tu: clang_tu = { index: null, tu: null }; // (its types are read after the loop)
    val alts: bool[2] = { false, true };
    for (alt) in alts {
        cts = {};
        var retry = false;
        for (a&) in cargs.items() {
            var c = this.c_spell(k, a.base, alt) ?? return fail(span, fmt2("C has no type for {}, an argument of {}", this.ty_name(a.base), S(callee)));
            retry = retry || (contains(c.as_str(), "long long") && contains(c.as_str(), "*"));
            put(&cts, move c);
        }
        var text = copy x.src;
        text.push('\n');
        var call = fmt("{}(", S(callee));
        shown = copy call;
        for (i) in 0..cts.len {
            val a = cargs.at(i);
            var cq = S("");
            if (a.mode == 2) {
                cq = S("const ");
            }
            text.append(fmt3("extern {}{} volt_a{};\n", move cq, copy *cts.at(i), unum(@cast<u64>(i))).as_str());
            if (i > 0) {
                call.append(", ");
                shown.append(", ");
            }
            if (a.mode == 3) {
                call.append(a.lit.as_str());
            } else {
                call.append(fmt("volt_a{}", unum(@cast<u64>(i))).as_str());
            }
            shown.append(cts.at(i).as_str());
        }
        call.push(')');
        shown.push(')');
        text.append(fmt("static __typeof__({}) *volt_r;\n", move call).as_str());
        tu = clang_parse(main, text.as_str(), &copts);
        val errs = tu.errors_text(main) ?? S("");
        if (errs.len() > 0) {
            if (!alt && retry) {
                continue;
            }
            return fail(span, fmt2("C can't make this call, {}:\n{}", copy shown, copy errs));
        }
        for (ch&) in children(clang::clang_getTranslationUnitCursor(tu.tu)).items() {
            if (clang::clang_getCursorKind(*ch) == clang::CXCursor_VarDecl && cursor_name(*ch).as_str() == "volt_r") {
                rt = clang::clang_getPointeeType(clang::clang_getCursorType(*ch));
            }
        }
        break;
    }
    val r = rt ?? return fails(span, "clang gave no type for the C call");
    val rc = this.cx_ctype(r, 0) ?? return fail(span, fmt2("{} gives a {}, which Volt has no type for", copy shown, type_spelling(clang::clang_getCanonicalType(r))));
    // its Volt and C result, through the import's names
    var m: cmapper = { d: &x.d, span: span };
    m.names = copy x.names;
    m.enum_names = copy x.enum_names;
    m.enum_ints = copy x.enum_ints;
    m.complex = copy x.complex;
    m.cf32 = x.cf32;
    m.cf64 = x.cf64;
    val vret = m.wrap_ty(&rc) ?? return fail(span, fmt2("{} gives a {}, which Volt has no type for", copy shown, type_spelling(clang::clang_getCanonicalType(r))));
    // the C function's parameters, and the call in it (a place through its address)
    var params = S("");
    var call = fmt("{}(", S(callee));
    for (i) in 0..cargs.len {
        val a = cargs.at(i);
        if (i > 0) {
            params.append(", ");
            call.append(", ");
        }
        val p = fmt("volt_a{}", unum(@cast<u64>(i)));
        if (a.mode == 1 || a.mode == 2) {
            if (a.mode == 2) {
                params.append("const ");
            }
            params.append(fmt2("{} *{}", copy *cts.at(i), copy p).as_str());
            call.append(fmt("(*{})", copy p).as_str());
        } else {
            params.append(fmt2("{} {}", copy *cts.at(i), copy p).as_str());
            if (a.mode == 3) {
                call.append(a.lit.as_str());
            } else {
                call.append(p.as_str());
            }
        }
    }
    call.push(')');
    if (cargs.len == 0) {
        params.append("void");
    }
    var ret = S("");
    var body = S("");
    match (rc) {
        .VOID => {
            ret = S("void");
            body = fmt("{};", copy call);
        },
        .LDOUBLE => {
            ret = S("double");
            body = fmt("return {};", copy call);
        },
        .COMPLEX(e) => {
            ret = fmt("volt_{}", S(complex_name(e)));
            body = fmt3("{} _Complex volt_z = {}; {} volt_o; volt_o.re = __real__ volt_z; volt_o.im = __imag__ volt_z; return volt_o;", S(e), copy call, copy ret);
        },
        default => {
            ret = m.c_text(&rc, &x.c_names) ?? return fail(span, fmt2("{} gives a {}, which Volt has no type for", copy shown, type_spelling(clang::clang_getCanonicalType(r))));
            if (spelled_ptr(&rc)) {
                body = fmt("return (void *){};", copy call);
            } else {
                body = fmt("return {};", copy call);
            }
        },
    }
    // a complex struct the import hadn't declared yet
    for (n) in m.complex.items() {
        var have = false;
        for (c) in x.complex.items() {
            have = have || c == n;
        }
        if (!have) {
            put(&x.complex, n);
            this.c_put_text(k, complex_c(n));
            try this.c_declare(k, m.complex_item(n, this.intern(fmt("volt_{}", S(n)))), span);
        }
    }
    // the C function, and the Volt fn bound to it
    var wn = S("volt_cu_");
    wn.append_uint(@cast<u64>(k));
    wn.push('_');
    wn.append_uint(@cast<u64>(this.c_used));
    this.c_used += 1;
    val cn = this.intern(move wn);
    this.c_put_text(k, fmt4("static __inline__ {} {}({}) {{ {} }}", move ret, S(cn), move params, move body));
    var ps: std::vec<param> = {};
    for (i) in 0..cargs.len {
        var pt = cargs.at(i).ty;
        match (*this.t.get(pt)) {
            .REF(y) => { pt = this.t.intern(tyk::PTR(y)); },
            default => {},
        }
        put(&ps, { name: this.intern(fmt("a{}", unum(@cast<u64>(i)))), ty: { kind: type_kind::RESOLVED(pt), span: span }, fallback: null, mutable: false, is_static: false, is_comptime: false, span: span });
    }
    val first = this.decls.len;
    try this.c_declare(k, m.citem(item_kind::FN({ name: cn, spec: null, params: move ps, c_varargs: false, ret: vret, body: null, is_async: false, is_comptime: false, extern_abi: C_HEADER, is_export: false, is_attach: false, c_name: cn })), span);
    for (j) in first..this.decls.len {
        if (this.fn_decl_of(@cast<u32>(j)) != null) {
            return @cast<u32>(j);
        }
    }
    return fails(span, "the C call's Volt fn wasn't declared");
}

// an item made for import k, declared in its namespace as its header's are (kept out of Volt's C
// with them)
attach fn c_declare(this: checker&, k: usize, it: item, span: span) -> compile_error!void {
    var mine = move it;
    val x = this.c_ctxs.at(k);
    if (x.keep) {
        var imp: c_imported = {};
        match (mine.kind) {
            .FN(f) => { put(&imp.statics, f.c_name ?? f.name); },
            default => {},
        }
        try this.keep_out(&mine, &imp, x.kept, span);
    }
    put(&this.owned_items, bx(move mine));
    this.importing_c = true;
    val r = this.collect_item(*this.owned_items.at(this.owned_items.len - 1), x.ns, null);
    this.importing_c = false;
    try r;
}
