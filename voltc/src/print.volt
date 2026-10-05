// std::io::println / print: format strings are checked at compile time and lowered to one print
// call per piece. A port of bootstrap/check/print.rs.
// ponytail: compiler intrinsic, move to Volt std once comptime can walk fmt strings.
use std::mem;

// a piece of a format string: text, or the index of the value that fills a {}
enum piece {
    TEXT: str,
    ARG: (usize, fspec?), // with its {:spec}, if it has one
}

// The formatting intrinsics std declares: println, print, eprintln, eprint (to stdout or stderr),
// write (to a writer: `std::write(&out, fmt, args...)`) and format (a new value of the type its
// declaration returns, `ret`). The format string splits into text and {} holes at compile time;
// the values go into temps in order, and temporaries that own something are deleted after
// printing. Everything goes through one sink (a volt_sink*): a stream, or a writer's write_str.
attach fn intrinsic(this: checker&, name: str, all_args: std::vec<expr>&, ret: u32, span: span) -> compile_error!tval {
    if (name != "println" && name != "print" && name != "eprintln" && name != "eprint" && name != "write" && name != "format") {
        return fail(span, fmt("unknown intrinsic '{}'", S(name)));
    }
    val newline = name == "println" || name == "eprintln";
    var code: std::vec<u32> = {};
    val sk = this.tmp_local("sk", VOIDPTR);
    var first: usize = 0; // where the format string is
    var result: local_ref? = null;
    if (name == "write") {
        if (all_args.len == 0) {
            return fails(span, "std::write takes a writer, a format and its values: std::write(&out, \"{}\", x)");
        }
        val target = all_args.at(0);
        val w = try this.expr(target, null);
        var wt: u32? = null;
        match (*this.t.get(w.ty)) {
            .REF(x) => { wt = x; },
            default => {},
        }
        val t = wt ?? return fails(target.span, "std::write takes a reference to the writer: std::write(&out, ...)");
        val h = (try this.hook(t, "write_str")) ?? return fail(target.span, fmt2("std::write needs a writer: {} doesn't attach write_str(this: {}&, s: str) -> void", this.ty_name(t), this.ty_name(t)));
        this.note_arg(body_key(BODY_FN, h), 0, &w, target.span, null);
        put(&code, this.ir.decl(sk.id, this.sink_of(t, h, this.ir.conv(w.c, VOIDPTR), &code)));
        first = 1;
    } else if (name == "format") {
        val h = (try this.hook(ret, "write_str")) ?? return fail(span, fmt2("std::format needs a writer type: {} doesn't attach write_str(this: {}&, s: str) -> void", this.ty_name(ret), this.ty_name(ret)));
        val none: std::vec<lit_entry> = {};
        val init = try this.literal(&none, ret, span);
        val fv = this.tmp_local("f", ret);
        put(&code, this.ir.decl(fv.id, init.c));
        put(&code, this.ir.decl(sk.id, this.sink_of(ret, h, this.ir.conv(this.ir.addr(fv.c, this.t.ref_to(ret)), VOIDPTR), &code)));
        result = fv;
    } else if (name[0] == 'e') {
        put(&code, this.ir.decl(sk.id, this.ir.rt_call("volt_stderr", {}, VOIDPTR)));
    } else {
        put(&code, this.ir.decl(sk.id, this.ir.rt_call("volt_stdout", {}, VOIDPTR)));
    }
    val sink = sk.c;
    var pieces: std::vec<piece> = {};
    // the first argument is a format string when values follow it or it has a {} in it
    var fmt_str: str? = null;
    var fmt_span: span = span;
    val nargs = all_args.len - first;
    if (nargs > 0) {
        match (all_args.at(first).kind) {
            .STR(s) => {
                if (nargs > 1 || contains(s.as_str(), "{}") || contains(s.as_str(), "{:") || has_name_hole(s.as_str())) {
                    fmt_str = s.as_str();
                    fmt_span = all_args.at(first).span;
                }
            },
            default => {},
        }
    }
    var first_value = first;
    var named: std::vec<expr> = {}; // {name}s: the values after the given ones
    if (fmt_str) {
        val f = fmt_str;
        var text: std::string = {};
        var next: usize = 0;
        var i: usize = 0;
        while (i < f.len) {
            val c = f[i];
            var d: u8 = 0;
            if (i + 1 < f.len) {
                d = f[i + 1];
            }
            if ((c == '{' && d == '{') || (c == '}' && d == '}')) {
                text.push(c);
                i += 2;
            } else if (c == '{' && d == '}') {
                var done: std::string = {};
                swap(&done, &text);
                put(&pieces, piece::TEXT(this.intern(move done)));
                put(&pieces, piece::ARG(next, null));
                next += 1;
                i += 2;
            } else if (c == '{' && d == ':') {
                var close = i + 2;
                while (close < f.len && f[close] != '}') {
                    close += 1;
                }
                if (close >= f.len) {
                    return fails(fmt_span, "use {} for a value, {{ and }} for braces");
                }
                var sp: fspec = {};
                val bad = parse_spec(f[i + 2..close], &sp);
                if (bad) {
                    return fail(fmt_span, copy bad);
                }
                var done: std::string = {};
                swap(&done, &text);
                put(&pieces, piece::TEXT(this.intern(move done)));
                if (close == i + 2) {
                    put(&pieces, piece::ARG(next, null)); // {:} is a plain {}
                } else {
                    put(&pieces, piece::ARG(next, sp));
                }
                next += 1;
                i = close + 1;
            } else if (c == '{' && ((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || d == '_')) {
                var close = i + 1;
                while (close < f.len && f[close] != '}') {
                    close += 1;
                }
                if (close >= f.len) {
                    return fails(fmt_span, "use {} for a value, {{ and }} for braces");
                }
                val inner = f[i + 1..close];
                // the name runs to a ':' that isn't part of a '::'
                var cut = inner.len;
                var k: usize = 0;
                while (k < inner.len) {
                    if (inner[k] == ':') {
                        if (k + 1 < inner.len && inner[k + 1] == ':') {
                            k += 2;
                            continue;
                        }
                        cut = k;
                        break;
                    }
                    k += 1;
                }
                var sp: fspec = {};
                var has_spec = false;
                if (cut < inner.len) {
                    val bad = parse_spec(inner[cut + 1..inner.len], &sp);
                    if (bad) {
                        return fail(fmt_span, copy bad);
                    }
                    has_spec = cut + 1 < inner.len;
                }
                val at = hole_at(this.files.at(@cast<usize>(fmt_span.file)).text, fmt_span, f, i + 1, cut);
                var e = this.name_expr(inner[0..cut], at, fmt_span) ?? return fails(fmt_span, "a name in a format string is a path like {x}, {a::B} or {p.x}");
                var done: std::string = {};
                swap(&done, &text);
                put(&pieces, piece::TEXT(this.intern(move done)));
                if (has_spec) {
                    put(&pieces, piece::ARG(nargs - 1 + named.len, sp));
                } else {
                    put(&pieces, piece::ARG(nargs - 1 + named.len, null));
                }
                put(&named, move e);
                i = close + 1;
            } else if (c == '{' || c == '}') {
                return fails(fmt_span, "use {} for a value, {{ and }} for braces");
            } else {
                text.push(c);
                i += 1;
            }
        }
        put(&pieces, piece::TEXT(this.intern(move text)));
        if (next != nargs - 1) {
            var m = S("format string has ");
            m.append_uint(@cast<u64>(next));
            m.append(" {} but ");
            m.append_uint(@cast<u64>(nargs - 1));
            m.append(" values were given");
            return fail(span, move m);
        }
        first_value = first + 1;
    } else {
        if (nargs > 1) {
            return fails(span, "println with several values needs a format string first: println(\"{} {}\", a, b)");
        }
        if (nargs > 0) {
            put(&pieces, piece::ARG(0, null));
        }
    }
    // evaluate values in order into temps
    var drops: std::vec<u32> = {};
    var temps: std::vec<local_ref> = {};
    var tys: std::vec<u32> = {};
    var spans: std::vec<span> = {};
    var vals: std::vec<expr*> = {};
    for (i) in first_value..all_args.len {
        put(&vals, all_args.at(i));
    }
    for (n&) in named.items() {
        put(&vals, n);
    }
    for (ap&) in vals.items() {
        val a = *ap ?? return fails(span, "");
        val v = try this.expr(a, null);
        if (v.ty == VOID || v.ty == NEVER) {
            return fails(a.span, "this has no value to print");
        }
        put(&spans, a.span);
        if (v.ty == NULL_TY) {
            put(&temps, { id: 0, c: v.c });
            put(&tys, NULL_TY);
            continue;
        }
        val t = this.tmp_local("p", v.ty);
        put(&code, this.ir.decl(t.id, v.c));
        if (!v.lv && (try this.needs_drop(v.ty))) {
            val d = try this.drop_fn(v.ty);
            put(&drops, this.call_fn(d, nodes(this.ir.addr(t.c, this.t.ref_to(v.ty))), VOID));
        }
        put(&temps, t);
        put(&tys, v.ty);
    }
    // the program's streams are held for the whole output, so threads' lines don't mix
    val stream = name != "write" && name != "format";
    if (stream) {
        put(&code, this.ir.rt_call("volt_lock_out", {}, VOID));
    }
    for (p&) in pieces.items() {
        match (*p) {
            .TEXT(s) => {
                if (s.len > 0) {
                    put(&code, this.out_s(sink, s));
                }
            },
            .ARG(i, sp) => {
                if (sp) {
                    try this.spec_code(&code, sink, temps.at(i).c, *tys.at(i), sp, *spans.at(i));
                } else {
                    try this.print_code(&code, sink, temps.at(i).c, *tys.at(i), span);
                }
            },
        }
    }
    if (newline) {
        put(&code, this.out_s(sink, "\n"));
    }
    if (stream) {
        put(&code, this.ir.rt_call("volt_unlock_out", {}, VOID));
    }
    for (d&) in drops.items() {
        put(&code, *d);
    }
    if (result) {
        val r = result;
        return vnew(ret, this.ir.seq(move code, r.c, ret));
    }
    return this.vstmt(this.ir.block(move code));
}

// a sink around a writer of type t: a (write, ctx) pair in a new local, the same layout as the
// runtime's volt_sink; its address (as a void*)
attach fn sink_of(this: checker&, t: u32, h: u32, ctx: u32, code: std::vec<u32>&) -> u32 {
    var ps: std::vec<u32> = {};
    put(&ps, VOIDPTR);
    put(&ps, STR);
    val fp = this.t.intern(tyk::FN_PTR(move ps, VOID, false));
    var es: std::vec<u32> = {};
    put(&es, fp);
    put(&es, VOIDPTR);
    var names: std::vec<str?> = {};
    put(&names, null);
    put(&names, null);
    val pair = this.t.intern(tyk::TUPLE(move es, move names));
    val st = this.tmp_local("sink", pair);
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: this.ir.node(ir_kind::FN(this.sink_fn(t, h)), fp) });
    put(&inits, { field: 1, value: ctx });
    put(code, this.ir.decl(st.id, this.ir.node(ir_kind::AGG(move inits), pair)));
    return this.ir.conv(this.ir.addr(st.c, this.t.ref_to(pair)), VOIDPTR);
}

// the glue fn a sink for a writer of type t calls: void f(void* ctx, str s), which calls the
// writer's write_str (h)
attach fn sink_fn(this: checker&, t: u32, h: u32) -> u32 {
    var k = S("sink");
    k.append_uint(@cast<u64>(t));
    val have = this.glue_names.get(k.as_str());
    if (have) {
        return *have;
    }
    var n = S("volt_sink_");
    n.append_uint(@cast<u64>(t));
    var irf: ir_fn = { name: this.intern(move n), params: {}, ret: VOID, link: linkage::STATIC, used: true };
    put(&irf.locals, { name: "ctx", ty: VOIDPTR });
    put(&irf.locals, { name: "s", ty: STR });
    put(&irf.params, 0);
    put(&irf.params, 1);
    put(&this.ir.fns, bx(move irf));
    val f = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.order, f);
    this.glue_names.put(this.intern(move k), f);
    this.use_fn(h);
    val ctx = this.ir.node(ir_kind::LOCAL(0), VOIDPTR);
    val s = this.ir.node(ir_kind::LOCAL(1), STR);
    val call = this.call_fn(this.fi(h).ir, nodes2(this.ir.conv(ctx, this.t.ref_to(t)), s), VOID);
    this.ir.fn_at(f).body = this.ir.block(nodes(call));
    put(&this.ir.bodies, f);
    return f;
}

// statements formatting value c of type t by a {:spec}: numbers, bool, text (str, cstr, a type
// that attaches as_str), and integers as characters with {:c}
attach fn spec_code(this: checker&, code: std::vec<u32>&, sink: u32, c: u32, t: u32, sp: fspec, span: span) -> compile_error!void {
    val kind = sp.ty;
    val for_ints = kind == 'x' || kind == 'X' || kind == 'b' || kind == 'o' || kind == 'c';
    val for_floats = kind == 'e' || kind == 'E';
    var k1 = S("");
    if (kind != 0) {
        k1.push(kind);
    }
    var pad: std::vec<u32> = {};
    put(&pad, sink);
    match (*this.t.get(t)) {
        .INT(k) => {
            if (sp.prec >= 0) {
                return fail(span, fmt("precision applies to floats and text, not {}", this.ty_name(t)));
            }
            if (for_floats) {
                return fail(span, fmt2("{:{}} formats floats, not {}", move k1, this.ty_name(t)));
            }
            if (k.signed()) {
                put(&pad, this.ir.conv(c, int_id(int_ty::I128)));
                put(&pad, this.ir.int(@cast<i128>(k.bits()), I32));
                this.spec_args(&pad, &sp, false);
                put(code, try this.rt_any("volt_fmt_i", move pad, VOID));
            } else {
                put(&pad, this.ir.conv(c, int_id(int_ty::U128)));
                put(&pad, this.ir.int(0, I32));
                this.spec_args(&pad, &sp, false);
                put(code, try this.rt_any("volt_fmt_u", move pad, VOID));
            }
            return;
        },
        .FLOAT(b) => {
            if (for_ints) {
                return fail(span, fmt2("{:{}} formats integers, not {}", move k1, this.ty_name(t)));
            }
            put(&pad, this.ir.conv(c, F64));
            var small = 0;
            if (b == 32) {
                small = 1;
            }
            put(&pad, this.ir.int(@cast<i128>(small), I32));
            this.spec_args(&pad, &sp, true);
            put(code, try this.rt_any("volt_fmt_f", move pad, VOID));
            return;
        },
        default => {},
    }
    var f: str? = null;
    match (*this.t.get(t)) {
        .BOOL => {
            put(&pad, this.ir.conv(c, I32));
            f = "volt_fmt_bool";
        },
        .STR => {
            put(&pad, c);
            f = "volt_fmt_text";
        },
        .CSTR => {
            put(&pad, c);
            f = "volt_fmt_cstr";
        },
        .STRUCT(sid) => {
            val h = try this.hook(t, "as_str");
            if (h) {
                this.use_fn(h);
                put(&pad, this.call_fn(this.fi(h).ir, nodes(this.ir.addr(c, this.t.ref_to(t))), STR));
                f = "volt_fmt_text";
            }
        },
        default => {},
    }
    val name = f ?? return fail(span, fmt("a format spec needs a number, bool, character or text, not {}", this.ty_name(t)));
    if (for_ints) {
        return fail(span, fmt2("{:{}} formats integers, not {}", move k1, this.ty_name(t)));
    }
    if (for_floats) {
        return fail(span, fmt2("{:{}} formats floats, not {}", move k1, this.ty_name(t)));
    }
    // text: fill, align, flags, width, precision
    put(&pad, this.ir.int(@cast<i128>(sp.fill), U32));
    put(&pad, this.ir.int(@cast<i128>(sp.align), I32));
    put(&pad, this.ir.int(@cast<i128>(sp.flags), I32));
    put(&pad, this.ir.int(@cast<i128>(sp.width), I32));
    put(&pad, this.ir.int(@cast<i128>(sp.prec), I32));
    put(code, try this.rt_any(name, move pad, VOID));
}

// a number's padding arguments: fill, align, flags, width, (precision,) type
attach fn spec_args(this: checker&, out: std::vec<u32>&, sp: fspec&, prec: bool) -> void {
    put(out, this.ir.int(@cast<i128>(sp.fill), U32));
    put(out, this.ir.int(@cast<i128>(sp.align), I32));
    put(out, this.ir.int(@cast<i128>(sp.flags), I32));
    put(out, this.ir.int(@cast<i128>(sp.width), I32));
    if (prec) {
        put(out, this.ir.int(@cast<i128>(sp.prec), I32));
    }
    put(out, this.ir.int(@cast<i128>(sp.ty), I32));
}

// a {:spec}: [[fill]align][sign][#][0][width][.precision][type]
struct fspec {
    fill: u32 = 32;  // a code point
    align: u8 = 0;   // '<', '>', '^' or 0 (numbers right, text left)
    flags: u8 = 0;   // 1 '+', 2 '#', 4 '0'
    width: i32 = -1; // -1: none
    prec: i32 = -1;  // -1: none
    ty: u8 = 0;      // 0 or one of x X b o e E c
}

// read the text between `{:` and `}` into sp; why it's bad, or null
fn parse_spec(s: str, sp: fspec&) -> std::string? {
    if (s.len == 0) {
        return null;
    }
    var i: usize = 0;
    // the first character may be a fill, when an alignment follows it
    val first = utf8_len(s[0]);
    if (first < s.len && is_align(s[first]) && first <= s.len) {
        sp.fill = utf8_decode(s[0..first]);
        sp.align = s[first];
        i = first + 1;
    } else if (is_align(s[0])) {
        sp.align = s[0];
        i = 1;
    }
    if (i < s.len && (s[i] == '+' || s[i] == '-')) {
        if (s[i] == '+') {
            sp.flags |= 1;
        }
        i += 1;
    }
    if (i < s.len && s[i] == '#') {
        sp.flags |= 2;
        i += 1;
    }
    if (i < s.len && s[i] == '0') {
        sp.flags |= 4;
        i += 1;
    }
    val w = spec_number(s, &i);
    if (w) {
        sp.width = w;
    }
    if (i < s.len && s[i] == '.') {
        i += 1;
        sp.prec = spec_number(s, &i) ?? return S("precision needs a number after the '.': {:.2}");
    }
    if (i < s.len) {
        val c = s[i];
        if (i + 1 == s.len && (c == 'x' || c == 'X' || c == 'b' || c == 'o' || c == 'e' || c == 'E' || c == 'c')) {
            sp.ty = c;
        } else {
            return fmt("unknown format type '{}' (x, X, b, o, e, E or c)", S(s[i..s.len]));
        }
    }
    return null;
}

fn is_align(c: u8) -> bool {
    return c == '<' || c == '>' || c == '^';
}

// digits at s[*i..] as a number (widths and precisions stop growing at a million); null: none
fn spec_number(s: str, i: usize&) -> i32? {
    val start = *i;
    var n: i32 = 0;
    while (*i < s.len && s[*i] >= '0' && s[*i] <= '9') {
        n = n * 10 + (s[*i] - '0') as i32;
        if (n > 1000000) {
            n = 1000000;
        }
        *i += 1;
    }
    if (*i == start) {
        return null;
    }
    return n;
}

// the byte length of the UTF-8 character that starts with byte b
fn utf8_len(b: u8) -> usize {
    if (b < 0x80) {
        return 1;
    }
    if (b >= 0xF0) {
        return 4;
    }
    if (b >= 0xE0) {
        return 3;
    }
    return 2;
}

// the code point of one UTF-8 character
fn utf8_decode(s: str) -> u32 {
    if (s.len == 1) {
        return s[0] as u32;
    }
    var cp = (s[0] as u32) & (0x7F >> s.len);
    for (i) in 1..s.len {
        cp = (cp << 6) | ((s[i] as u32) & 0x3F);
    }
    return cp;
}

// volt_out(sink, fmt, args...)
attach fn out(this: checker&, sink: u32, f: str, args: std::vec<u32>) -> u32 {
    var all = nodes2(sink, this.ir.node(ir_kind::CSTR(f), CSTR));
    for (a&) in args.items() {
        put(&all, *a);
    }
    return this.ir.rt_call("volt_out", move all, VOID);
}

// print text as is: its bytes and length, no printf (bare metal has none)
attach fn out_s(this: checker&, sink: u32, s: str) -> u32 {
    return this.ir.rt_call("volt_put", nodes3(sink, this.ir.node(ir_kind::CSTR(s), CSTR), this.ir.int(@cast<i128>(s.len), USIZE)), VOID);
}

// name(sink, v) through std's Volt version of that runtime function (@runtime), if it has one
// a call to runtime function `name`: std's Volt version (@runtime) when it has one, else the C one
attach fn rt_any(this: checker&, name: str, args: std::vec<u32>, t: u32) -> compile_error!u32 {
    val d = this.runtime_impls.get(name) ?? return this.ir.rt_call(name, move args, t);
    val f = try this.fn_inst(*d, {}, {});
    this.use_fn(f);
    return this.call_fn(this.fi(f).ir, move args, t);
}

attach fn rt_print(this: checker&, name: str, sink: u32, v: u32) -> compile_error!(u32?) {
    val d = this.runtime_impls.get(name) ?? return null;
    val f = try this.fn_inst(*d, {}, {});
    this.use_fn(f);
    return this.call_fn(this.fi(f).ir, nodes2(sink, v), VOID);
}

// f(sink, v): one of the runtime's print helpers
attach fn out_rt(this: checker&, sink: u32, f: str, v: u32) -> u32 {
    return this.ir.rt_call(f, nodes2(sink, v), VOID);
}

// statements printing value c (a place) of type t
attach fn print_code(this: checker&, code: std::vec<u32>&, sink: u32, c: u32, t: u32, span: span) -> compile_error!void {
    match (*this.t.get(t)) {
        .INT(k) => {
            if (k.bits() == 128) {
                if (k.signed()) {
                    put(code, (try this.rt_print("volt_print_i128", sink, c)) ?? this.out_rt(sink, "volt_print_i128", c));
                } else {
                    put(code, (try this.rt_print("volt_print_u128", sink, c)) ?? this.out_rt(sink, "volt_print_u128", c));
                }
            } else if (k.signed()) {
                val v = this.ir.conv(c, I64);
                put(code, (try this.rt_print("volt_print_i64", sink, v)) ?? this.out(sink, "%lld", nodes(v)));
            } else {
                val v = this.ir.conv(c, int_id(int_ty::U64));
                put(code, (try this.rt_print("volt_print_u64", sink, v)) ?? this.out(sink, "%llu", nodes(v)));
            }
        },
        .FLOAT(b) => {
            if (b == 32) {
                val v = this.ir.conv(c, F32);
                put(code, (try this.rt_print("volt_print_f32", sink, v)) ?? this.out_rt(sink, "volt_print_f32", v));
            } else {
                val v = this.ir.conv(c, F64);
                put(code, (try this.rt_print("volt_print_f64", sink, v)) ?? this.out_rt(sink, "volt_print_f64", v));
            }
        },
        .BOOL => { put(code, this.ir.if_(c, this.ir.block(nodes(this.out_s(sink, "true"))), this.ir.block(nodes(this.out_s(sink, "false"))))); },
        .STR => { put(code, this.out_rt(sink, "volt_print_str", c)); },
        .CSTR => { put(code, (try this.rt_print("volt_print_cstr", sink, c)) ?? this.out(sink, "%s", nodes(c))); },
        .NULL => { put(code, this.out_s(sink, "null")); },
        .REF(x) => { put(code, this.out(sink, "%p", nodes(this.ir.conv(c, VOIDPTR)))); },
        .FN_PTR(ps, r, va) => { put(code, this.out(sink, "%p", nodes(this.ir.conv(c, VOIDPTR)))); },
        .PTR(x) => { try this.print_ptr(code, sink, c); },
        .VOIDPTR => { try this.print_ptr(code, sink, c); },
        .FN_VAL(ps, r) => { put(code, this.out_s(sink, "<fn>")); },
        .CLOSURE(x) => { put(code, this.out_s(sink, "<fn>")); },
        .OPT(inner) => {
            val p = this.opt_parts(t, c);
            var some: std::vec<u32> = {};
            try this.print_code(&some, sink, p.value, inner, span);
            put(code, this.ir.if_(p.has, this.ir.block(move some), this.out_s(sink, "null")));
        },
        .ARRAY(et, n) => { try this.print_elems(code, sink, c, et, this.ir.int(@cast<i128>(n), USIZE), false, span); },
        .SLICE(et) => { try this.print_elems(code, sink, c, et, this.ir.field(c, 1, USIZE), true, span); },
        .TUPLE(ts, names) => {
            val xs = copy ts;
            put(code, this.out_s(sink, "("));
            for (i) in 0..xs.len {
                if (i > 0) {
                    put(code, this.out_s(sink, ", "));
                }
                val et = *xs.at(i);
                try this.print_code(code, sink, this.ir.field(c, @cast<u32>(i), et), et, span);
            }
            put(code, this.out_s(sink, ")"));
        },
        .RANGE(x) => {
            try this.print_code(code, sink, this.ir.field(c, 0, x), x, span);
            put(code, this.out_s(sink, ".."));
            try this.print_code(code, sink, this.ir.field(c, 1, x), x, span);
        },
        .STRUCT(sid) => {
            // a type that attaches as_str(this: T&) -> str prints as that text (std's string does)
            val h = try this.hook(t, "as_str");
            if (h) {
                this.use_fn(h);
                val s = this.call_fn(this.fi(h).ir, nodes(this.ir.addr(c, this.t.ref_to(t))), STR);
                put(code, this.out_rt(sink, "volt_print_str", s));
                return;
            }
            val own = this.owner(t);
            if (own) {
                val o = own;
                val p = this.ir.field(c, o.index, this.t.ref_to(o.inner));
                return this.print_code(code, sink, this.ir.deref(p, o.inner), o.inner, span);
            }
            val nf = (try this.struct_fields(sid, span)).len;
            var open = S(this.si(sid).name);
            open.append(" { ");
            put(code, this.out_s(sink, this.intern(move open)));
            for (i) in 0..nf {
                val f = *(try this.struct_fields(sid, span)).at(i);
                var label: std::string = {};
                if (i > 0) {
                    label.append(", ");
                }
                label.append(f.name);
                label.append(": ");
                put(code, this.out_s(sink, this.intern(move label)));
                try this.print_code(code, sink, this.ir.field(c, @cast<u32>(i), f.ty), f.ty, span);
            }
            put(code, this.out_s(sink, " }"));
        },
        .ENUM(e) => { try this.print_enum(code, sink, c, e, span); },
        .TRAIT_UNION(u) => {
            val members = copy this.ui(u).members;
            var cases: std::vec<case_arm> = {};
            for (i) in 0..members.len {
                val m = *members.at(i);
                var arm: std::vec<u32> = {};
                try this.print_code(&arm, sink, this.ir.field(c, @cast<u32>(i) + 1, m), m, span);
                put(&cases, { value: @cast<i128>(i), body: this.ir.block(move arm) });
            }
            put(code, this.ir.node(ir_kind::SWITCH(this.ir.field(c, 0, int_id(int_ty::U16)), move cases, null), VOID));
        },
        .ANYERR => {
            val n = this.call_fn(this.err_name_fn(), nodes(c), CSTR);
            put(code, (try this.rt_print("volt_print_cstr", sink, n)) ?? this.out(sink, "%s", nodes(n)));
        },
        .ERR_UNION(e, x) => {
            var bad = nodes(this.out_s(sink, "error."));
            try this.print_code(&bad, sink, this.ir.field(c, 0, e), e, span);
            var good: std::vec<u32> = {};
            if (x != VOID) {
                try this.print_code(&good, sink, this.ir.field(c, 1, x), x, span);
            }
            put(code, this.ir.if_(this.nonzero(this.eu_code(t, c)), this.ir.block(move bad), this.ir.block(move good)));
        },
        default => { return fail(span, fmt("can't print a {} yet", this.ty_name(t))); },
    }
}

// a raw pointer: its address, or null
attach fn print_ptr(this: checker&, code: std::vec<u32>&, sink: u32, c: u32) -> compile_error!void {
    val p = this.tmp_local("pp", VOIDPTR);
    put(code, this.ir.decl(p.id, this.ir.conv(c, VOIDPTR)));
    val is_null = this.ir.binary(binop_ir::EQ, p.c, this.ir.node(ir_kind::NULLPTR, VOIDPTR), BOOL);
    put(code, this.ir.if_(is_null, this.out_s(sink, "null"), this.out(sink, "%p", nodes(p.c))));
}

// { a, b, c } for an array (c is the array) or a slice
attach fn print_elems(this: checker&, code: std::vec<u32>&, sink: u32, c: u32, et: u32, n: u32, slice: bool, span: span) -> compile_error!void {
    val i = this.tmp_local("i", USIZE);
    var elem: u32 = 0;
    if (slice) {
        elem = this.ir.index(this.ir.field(c, 0, this.t.intern(tyk::PTR(et))), i.c, et);
    } else {
        elem = this.ir.index(c, i.c, et);
    }
    val pt = this.t.ref_to(et);
    val e = this.tmp_local("e", pt);
    var body = nodes(this.ir.decl(e.id, this.ir.addr(elem, pt)));
    val not_first = this.ir.binary(binop_ir::NE, i.c, this.ir.int(0, USIZE), BOOL);
    put(&body, this.ir.if_(not_first, this.out_s(sink, ", "), null));
    try this.print_code(&body, sink, this.ir.deref(e.c, et), et, span);
    put(code, this.out_s(sink, "{ "));
    for (s&) in this.counted_loop(i, n, this.ir.block(move body)).items() {
        put(code, *s);
    }
    put(code, this.out_s(sink, " }"));
}

// an enum value as VARIANT, or VARIANT(payload) (a tuple payload brings its own parens)
attach fn print_enum(this: checker&, code: std::vec<u32>&, sink: u32, c: u32, eid: u32, span: span) -> compile_error!void {
    val payloads = copy *(try this.enum_payloads(eid, span));
    val names = copy this.ei(eid).names;
    val values = copy this.ei(eid).values;
    var cases: std::vec<case_arm> = {};
    for (i) in 0..names.len {
        var arm = nodes(this.out_s(sink, *names.at(i)));
        val pt = *payloads.at(i);
        if (pt) {
            val x = pt;
            var is_tuple = false;
            match (*this.t.get(x)) {
                .TUPLE(ts, ns) => { is_tuple = true; },
                default => {},
            }
            if (!is_tuple) {
                put(&arm, this.out_s(sink, "("));
            }
            try this.print_code(&arm, sink, this.ir.field(c, @cast<u32>(i) + 1, x), x, span);
            if (!is_tuple) {
                put(&arm, this.out_s(sink, ")"));
            }
        }
        put(&cases, { value: *values.at(i), body: this.ir.block(move arm) });
    }
    put(code, this.ir.node(ir_kind::SWITCH(this.tag_of(eid, c), move cases, this.out_s(sink, "<invalid>")), VOID));
}

// volt_err_name(code), made by error_table once every error set is known
attach fn err_name_fn(this: checker&) -> u32 {
    if (this.err_name) {
        return this.err_name;
    }
    var irf: ir_fn = { name: "volt_err_name", params: {}, ret: CSTR, link: linkage::STATIC, used: true };
    put(&irf.locals, { name: "c", ty: U32 });
    put(&irf.params, 0);
    put(&this.ir.fns, bx(move irf));
    val f = @cast<u32>(this.ir.fns.len - 1);
    put(&this.ir.order, f);
    this.err_name = f;
    return f;
}

// whether a format string has a {name} in it (not a {{ escape)
fn has_name_hole(s: str) -> bool {
    var i: usize = 0;
    while (i + 1 < s.len) {
        if (s[i] == '{') {
            val d = s[i + 1];
            if (d == '{') {
                i += 2;
                continue;
            }
            if ((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || d == '_') {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

// a word of a {name}: letters, digits and _, not starting with a digit unless it's a field (t.0)
fn fmt_word(w: str, digit_first: bool) -> bool {
    if (w.len == 0 || (!digit_first && w[0] >= '0' && w[0] <= '9')) {
        return false;
    }
    for (c) in w {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
            return false;
        }
    }
    return true;
}

// where the source writes the {name} whose name starts at byte i of the format string fmt (from the
// literal at sp), as a span of its len bytes: found when the literal is a plain or raw string whose
// source holds the same bytes up to there (no escape before it); else null
fn hole_at(text: str, sp: span, fmt: str, i: usize, len: usize) -> span? {
    val lo = @cast<usize>(sp.lo);
    val hi = @cast<usize>(sp.hi);
    if (hi > text.len || lo > hi) {
        return null;
    }
    val src = text[lo..hi];
    var off: usize = 0;
    if (src.starts_with("\"\"\"") || src.starts_with("r\"\"\"")) {
        return null; // a multi-line string's lines lose their indentation
    } else if (src.starts_with("r\"")) {
        off = 2;
    } else if (src.starts_with("\"")) {
        off = 1;
    } else {
        return null;
    }
    if (off + i + len > src.len || src[off..off + i + len] != fmt[0..i + len]) {
        return null;
    }
    return { file: sp.file, lo: sp.lo + @cast<u32>(off + i), hi: sp.lo + @cast<u32>(off + i + len) };
}

// `{a::b.c.0}`'s value: the path a::b, then field c, then element 0 (`this` names the receiver). Each
// part spans what it covers of the name where the source writes it (at), else the string's span
attach fn name_expr(this: checker&, name: str, at: span?, sp0: span) -> expr? {
    var dot = name.len;
    for (c, i) in name {
        if (c == '.') {
            dot = i;
            break;
        }
    }
    var segs: std::vec<path_seg> = {};
    var seg: usize = 0;
    var k: usize = 0;
    while (k <= dot) {
        if (k == dot || (k + 1 < dot && name[k] == ':' && name[k + 1] == ':')) {
            val w = name[seg..k];
            if (!fmt_word(w, false)) {
                return null;
            }
            put(&segs, { name: this.intern_str(w), args: null });
            if (k == dot) {
                break;
            }
            k += 2;
            seg = k;
            continue;
        }
        k += 1;
    }
    val ps = sub_span(at, sp0, dot);
    var e: expr = { kind: expr_kind::THIS, span: ps };
    if (segs.len != 1 || segs.at(0).name != "this") {
        e = { kind: expr_kind::PATH({ segs: move segs, span: ps }), span: ps };
    }
    var start = dot + 1;
    var j = dot + 1;
    while (dot < name.len && j <= name.len) {
        if (j == name.len || name[j] == '.') {
            val w = name[start..j];
            if (!fmt_word(w, true)) {
                return null;
            }
            e = { kind: expr_kind::FIELD(bx(move e), this.intern_str(w), null), span: sub_span(at, sp0, j) };
            start = j + 1;
        }
        j += 1;
    }
    return e;
}

// the first n bytes of a name at `at`, or the whole string's span when it isn't found there
fn sub_span(at: span?, whole: span, n: usize) -> span {
    val s = at ?? return whole;
    return { file: s.file, lo: s.lo, hi: s.lo + @cast<u32>(n) };
}
