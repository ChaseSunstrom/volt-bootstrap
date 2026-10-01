// The canonical text form of the tree: a port of bootstrap/sexp.rs, byte for byte, so the two parsers can
// be compared. Nodes are (tag fields...), lists [...], absent values _, bools t/f, names "..."
// (bytes outside printable ASCII as \xx), spans @lo:hi, floats by their bits.
use std::mem;

// prints nodes in the canonical form into `out`. Most writers put a space before what they write; ty,
// path, pat, block, let_stmt, fn_decl and item don't, so their callers add one
struct sexp_writer {
    out: std::string;
}

fn hex_digit(d: u64) -> u8 {
    if (d < 10) {
        return @cast<u8>(d) + '0';
    }
    return @cast<u8>(d - 10) + 'a';
}

fn binop_text(op: binop) -> str {
    match (op) {
        .ADD => { return "+"; },
        .SUB => { return "-"; },
        .MUL => { return "*"; },
        .DIV => { return "/"; },
        .REM => { return "%"; },
        .WADD => { return "+%"; },
        .WSUB => { return "-%"; },
        .WMUL => { return "*%"; },
        .AND => { return "&&"; },
        .OR => { return "||"; },
        .BITAND => { return "&"; },
        .BITOR => { return "|"; },
        .BITXOR => { return "^"; },
        .SHL => { return "<<"; },
        .SHR => { return ">>"; },
        .EQ => { return "=="; },
        .NE => { return "!="; },
        .LT => { return "<"; },
        .GT => { return ">"; },
        .LE => { return "<="; },
        .GE => { return ">="; },
    }
}

attach fn s(this: sexp_writer&, t: str) -> void {
    this.out.append(t);
}

attach fn open(this: sexp_writer&, tag: str) -> void {
    this.out.push('(');
    this.out.append(tag);
}

attach fn close(this: sexp_writer&) -> void {
    this.out.push(')');
}

attach fn sp(this: sexp_writer&) -> void {
    this.out.push(' ');
}

attach fn span(this: sexp_writer&, s: span) -> void {
    this.out.append(" @");
    this.out.append_uint(@cast<u64>(s.lo));
    this.out.push(':');
    this.out.append_uint(@cast<u64>(s.hi));
}

// a quoted string; bytes outside printable ASCII, `"` and `\` print as \xx
attach fn name(this: sexp_writer&, b: str) -> void {
    this.out.append(" \"");
    for (i) in 0..b.len {
        val c = b[i];
        if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') {
            this.out.push(c);
        } else {
            this.out.push('\\');
            this.out.push(hex_digit(@cast<u64>(c >> 4)));
            this.out.push(hex_digit(@cast<u64>(c & 15)));
        }
    }
    this.out.push('"');
}

attach fn flag(this: sexp_writer&, b: bool) -> void {
    if (b) {
        this.out.append(" t");
    } else {
        this.out.append(" f");
    }
}

attach fn none(this: sexp_writer&) -> void {
    this.out.append(" _");
}

attach fn vis(this: sexp_writer&, v: vis) -> void {
    match (v) {
        .INTERNAL => { this.out.append(" internal"); },
        .PUBLIC => { this.out.append(" public"); },
    }
}

attach fn opt_name(this: sexp_writer&, n: str?) -> void {
    if (n) {
        this.name(n);
    } else {
        this.none();
    }
}

// the opt_* writers read the optional's none/value fields through a pointer, so the node isn't copied;
// an absent value prints as ` _`
attach fn opt_expr(this: sexp_writer&, e: expr?*) -> void {
    if ((*e).none) {
        this.none();
    } else {
        this.expr(&(*e).value);
    }
}

attach fn opt_ty(this: sexp_writer&, t: ty?*) -> void {
    if ((*t).none) {
        this.none();
    } else {
        this.sp();
        this.ty(&(*t).value);
    }
}

attach fn gargs(this: sexp_writer&, a: std::vec<garg>&) -> void {
    this.out.append(" [");
    for (g&) in a.items() {
        this.garg(g);
    }
    this.out.append(" ]");
}

attach fn opt_gargs(this: sexp_writer&, a: std::vec<garg>?*) -> void {
    if ((*a).none) {
        this.none();
    } else {
        this.gargs(&(*a).value);
    }
}

// one line per top-level item
attach fn items(this: sexp_writer&, items: std::vec<item>&) -> void {
    for (it&) in items.items() {
        this.item(it);
        this.out.push('\n');
    }
}

// the items of a trait, attach block or namespace, as a ` [ ... ]` list
attach fn item_list(this: sexp_writer&, items: std::vec<item>&) -> void {
    this.out.append(" [");
    for (it&) in items.items() {
        this.sp();
        this.item(it);
    }
    this.out.append(" ]");
}

attach fn item(this: sexp_writer&, it: item&) -> void {
    this.open("item");
    this.span(it.span);
    this.out.append(" [");
    for (a&) in it.attrs.items() {
        this.expr(a);
    }
    this.out.append(" ]");
    this.out.append(" [");
    for (g&) in it.generics.items() {
        this.generic_param(g);
    }
    this.out.append(" ]");
    this.vis(it.vis);
    this.sp();
    match (it.kind) {
        .FN(f&) => { this.fn_decl(f); },
        .STRUCT(s&) => {
            this.open("struct");
            this.name(s.name);
            this.opt_gargs(&s.spec);
            this.out.append(" [");
            for (f&) in s.fields.items() {
                this.sp();
                this.open("field");
                this.name(f.name);
                this.sp();
                this.ty(&f.ty);
                this.opt_expr(&f.fallback);
                this.vis(f.vis);
                this.span(f.span);
                this.close();
            }
            this.out.append(" ]");
            this.flag(s.is_extern);
            this.flag(s.is_comptime);
            this.close();
        },
        .ENUM(e&) => {
            this.open("enum");
            this.name(e.name);
            this.opt_ty(&e.backing);
            this.out.append(" [");
            for (v&) in e.variants.items() {
                this.sp();
                this.open("variant");
                this.name(v.name);
                this.opt_ty(&v.payload);
                this.opt_expr(&v.value);
                this.span(v.span);
                this.close();
            }
            this.out.append(" ]");
            this.flag(e.is_error);
            this.close();
        },
        .TRAIT(n, fns&) => {
            this.open("trait");
            this.name(n);
            this.item_list(fns);
            this.close();
        },
        .ATTACH(tr&, target&, fns&) => {
            this.open("attach");
            this.sp();
            this.ty(tr);
            this.sp();
            this.ty(target);
            this.item_list(fns);
            this.close();
        },
        .NAMESPACE(p, items&) => {
            this.open("namespace");
            this.out.append(" [");
            for (n&) in p.items() {
                this.name(*n);
            }
            this.out.append(" ]");
            this.item_list(items);
            this.close();
        },
        .USE(p&) => {
            this.open("use");
            this.sp();
            this.path(p);
            this.close();
        },
        .USE_C(headers, alias) => {
            this.open("usec");
            this.out.append(" [");
            for (h&) in headers.items() {
                this.name(h.as_str());
            }
            this.out.append(" ]");
            this.name(alias);
            this.close();
        },
        .USE_LANG(lang, args, alias) => {
            this.open("uselang");
            this.name(lang);
            this.out.append(" [");
            for (h&) in args.items() {
                this.name(h.as_str());
            }
            this.out.append(" ]");
            this.name(alias);
            this.close();
        },
        .USE_CPP(headers, alias) => {
            this.open("usecpp");
            this.out.append(" [");
            for (h&) in headers.items() {
                this.name(h.as_str());
            }
            this.out.append(" ]");
            this.name(alias);
            this.close();
        },
        .GLOBAL(l&) => {
            this.open("global");
            this.sp();
            this.let_stmt(l);
            this.close();
        },
        .ALIAS(n, t&) => {
            // only C imports make these; the parser never does
            this.open("alias");
            this.name(n);
            this.sp();
            this.ty(t);
            this.close();
        },
    }
    this.close();
}

attach fn fn_decl(this: sexp_writer&, f: fn_decl&) -> void {
    this.open("fn");
    this.name(f.name);
    this.opt_gargs(&f.spec);
    this.params(&f.params);
    this.flag(f.c_varargs);
    this.opt_ty(&f.ret);
    if (f.body) {
        this.sp();
        this.block(&f.body);
    } else {
        this.none();
    }
    this.flag(f.is_async);
    this.flag(f.is_comptime);
    this.opt_name(f.extern_abi);
    this.flag(f.is_export);
    this.flag(f.is_attach);
    this.close();
}

attach fn params(this: sexp_writer&, ps: std::vec<param>&) -> void {
    this.out.append(" [");
    for (p&) in ps.items() {
        this.sp();
        this.open("param");
        this.name(p.name);
        this.opt_ty(&p.ty);
        this.opt_expr(&p.fallback);
        this.flag(p.mutable);
        this.flag(p.is_static);
        this.flag(p.is_comptime);
        this.span(p.span);
        this.close();
    }
    this.out.append(" ]");
}

attach fn generic_param(this: sexp_writer&, g: generic_param&) -> void {
    this.sp();
    this.open("gparam");
    this.name(g.name);
    this.out.append(" [");
    for (t&) in g.bounds.items() {
        this.sp();
        this.ty(t);
    }
    this.out.append(" ]");
    this.flag(g.pack);
    if (g.fallback) {
        this.garg(&g.fallback);
    } else {
        this.none();
    }
    this.span(g.span);
    this.close();
}

attach fn garg(this: sexp_writer&, g: garg&) -> void {
    this.sp();
    match (*g) {
        .TYPE(t&) => {
            this.open("gtype");
            this.sp();
            this.ty(t);
        },
        .EXPR(e&) => {
            this.open("gexpr");
            this.expr(e);
        },
    }
    this.close();
}

attach fn path(this: sexp_writer&, p: path&) -> void {
    this.open("path");
    this.out.append(" [");
    for (s&) in p.segs.items() {
        this.sp();
        this.open("seg");
        this.name(s.name);
        this.opt_gargs(&s.args);
        this.close();
    }
    this.out.append(" ]");
    this.span(p.span);
    this.close();
}

attach fn ty(this: sexp_writer&, t: ty&) -> void {
    match (t.kind) {
        .PATH(p&) => {
            this.open("tpath");
            this.sp();
            this.path(p);
        },
        .REF(i) => {
            this.open("tref");
            this.sp();
            this.ty(i);
        },
        .PTR(i) => {
            this.open("tptr");
            this.sp();
            this.ty(i);
        },
        .OPTIONAL(i) => {
            this.open("topt");
            this.sp();
            this.ty(i);
        },
        .ARRAY(i, n&) => {
            this.open("tarray");
            this.sp();
            this.ty(i);
            this.opt_box(n);
        },
        .SLICE(i) => {
            this.open("tslice");
            this.sp();
            this.ty(i);
        },
        .TUPLE(es) => {
            this.open("ttuple");
            this.out.append(" [");
            for (e&) in es.items() {
                this.opt_name(e.name);
                this.sp();
                this.ty(&e.ty);
            }
            this.out.append(" ]");
        },
        .ERROR_UNION(e, v) => {
            this.open("terr");
            if (e) {
                this.sp();
                this.ty(e);
            } else {
                this.none();
            }
            this.sp();
            this.ty(v);
        },
        .FN(f) => {
            this.open("tfn");
            this.out.append(" [");
            for (p&) in f.params.items() {
                this.sp();
                this.ty(p);
            }
            this.out.append(" ]");
            this.flag(f.c_varargs);
            this.sp();
            this.ty(f.ret);
            this.flag(f.extern_c);
        },
        .PACK(i) => {
            this.open("tpack");
            this.sp();
            this.ty(i);
        },
        .EXPR(e) => {
            this.open("texpr");
            this.expr(e);
        },
    }
    this.span(t.span);
    this.close();
}

attach fn block(this: sexp_writer&, b: block&) -> void {
    this.open("block");
    this.out.append(" [");
    for (s&) in b.stmts.items() {
        this.stmt(s);
    }
    this.out.append(" ]");
    this.span(b.span);
    this.close();
}

attach fn let_stmt(this: sexp_writer&, l: let_stmt&) -> void {
    this.open("let");
    this.flag(l.mutable);
    this.flag(l.is_comptime);
    this.flag(l.is_static);
    this.sp();
    this.pat(&l.pat);
    this.opt_ty(&l.ty);
    this.opt_expr(&l.init);
    this.span(l.span);
    this.close();
}

attach fn stmt(this: sexp_writer&, s: stmt&) -> void {
    this.sp();
    match (s.kind) {
        .LET(l&) => { this.let_stmt(l); },
        .EXPR(e&) => {
            this.open("sexpr");
            this.expr(e);
            this.close();
        },
        .DEFER(e&) => {
            this.open("defer");
            this.expr(e);
            this.close();
        },
        .ERR_DEFER(e&) => {
            this.open("errdefer");
            this.expr(e);
            this.close();
        },
        .SUSPEND => { this.s("(suspend)"); },
        .RESUME(e&) => {
            this.open("resume");
            this.expr(e);
            this.close();
        },
    }
    this.span(s.span);
}

attach fn pat_list(this: sexp_writer&, ps: std::vec<pat>&) -> void {
    this.out.append(" [");
    for (p&) in ps.items() {
        this.sp();
        this.pat(p);
    }
    this.out.append(" ]");
}

attach fn pat(this: sexp_writer&, p: pat&) -> void {
    match (p.kind) {
        .WILD => { this.open("pwild"); },
        .BIND(n) => {
            this.open("pbind");
            this.name(n);
        },
        .BIND_REF(n) => {
            this.open("pbindref");
            this.name(n);
        },
        .LIT(e&) => {
            this.open("plit");
            this.expr(e);
        },
        .RANGE(a&, b&, incl) => {
            this.open("prange");
            this.expr(a);
            this.expr(b);
            this.flag(incl);
        },
        .CTOR(c, args) => {
            this.open("pctor");
            match (c) {
                .DOT(n) => {
                    this.s(" dot");
                    this.name(n);
                },
                .PATH(cp&) => {
                    this.sp();
                    this.path(cp);
                },
            }
            if (args) {
                this.pat_list(&args);
            } else {
                this.none();
            }
        },
        .TUPLE(ps&) => {
            this.open("ptuple");
            this.pat_list(ps);
        },
    }
    this.span(p.span);
    this.close();
}

attach fn expr_list(this: sexp_writer&, es: std::vec<expr>&) -> void {
    this.out.append(" [");
    for (e&) in es.items() {
        this.expr(e);
    }
    this.out.append(" ]");
}

attach fn opt_box(this: sexp_writer&, e: std::box<expr>?*) -> void {
    if ((*e).none) {
        this.none();
    } else {
        this.expr((*e).value);
    }
}

attach fn expr(this: sexp_writer&, e: expr&) -> void {
    this.sp();
    match (e.kind) {
        .INT(v) => {
            this.s("(int ");
            append_u128(&this.out, v);
        },
        .FLOAT(v) => {
            var f = v;
            val bits = *@cast<u64&>(&f);
            this.s("(float ");
            var shift: u64 = 64;
            while (shift > 0) {
                shift -= 4;
                this.out.push(hex_digit((bits >> shift) & 15));
            }
        },
        .CHAR(v) => {
            this.s("(char ");
            this.out.append_uint(@cast<u64>(v));
        },
        .STR(s) => {
            this.open("str");
            this.name(s.as_str());
        },
        .BOOL(b) => {
            if (b) {
                this.s("(true");
            } else {
                this.s("(false");
            }
        },
        .NULL => { this.open("null"); },
        .THIS => { this.open("this"); },
        .ERROR_ANY => { this.open("errorany"); },
        .PATH(p&) => {
            this.open("epath");
            this.sp();
            this.path(p);
        },
        .DOT_VARIANT(n) => {
            this.open("dotvariant");
            this.name(n);
        },
        .UNARY(op, x) => {
            this.open("unary");
            match (op) {
                .NEG => { this.s(" -"); },
                .NOT => { this.s(" !"); },
                .BITNOT => { this.s(" ~"); },
                .ADDR => { this.s(" &"); },
                .DEREF => { this.s(" *"); },
            }
            this.expr(x);
        },
        .BINARY(op, a, b) => {
            this.open("binary");
            this.sp();
            this.s(binop_text(op));
            this.expr(a);
            this.expr(b);
        },
        .ASSIGN(op, a, b) => {
            this.open("assign");
            if (op) {
                this.sp();
                this.s(binop_text(op));
            } else {
                this.none();
            }
            this.expr(a);
            this.expr(b);
        },
        .INC_DEC(x, inc) => {
            this.open("incdec");
            this.expr(x);
            this.flag(inc);
        },
        .CAST(x, t&) => {
            this.open("cast");
            this.expr(x);
            this.sp();
            this.ty(t);
        },
        .RANGE(a&, b&, incl) => {
            this.open("range");
            this.opt_box(a);
            this.opt_box(b);
            this.flag(incl);
        },
        .CALL(f, args&) => {
            this.open("call");
            this.expr(f);
            this.expr_list(args);
        },
        .FIELD(x, n, args&) => {
            this.open("field");
            this.expr(x);
            this.name(n);
            this.opt_gargs(args);
        },
        .INDEX(x, i) => {
            this.open("index");
            this.expr(x);
            this.expr(i);
        },
        .BUILTIN(n, gargs&, args&) => {
            this.open("builtin");
            this.name(n);
            this.gargs(gargs);
            this.opt_gargs(args);
        },
        .TUPLE(es&) => {
            this.open("tuple");
            this.expr_list(es);
        },
        .LITERAL(es) => {
            this.open("literal");
            this.out.append(" [");
            for (le&) in es.items() {
                this.opt_name(le.name);
                this.expr(&le.value);
            }
            this.out.append(" ]");
        },
        .CLOSURE(c&) => {
            this.open("closure");
            this.out.append(" [");
            for (cap&) in c.caps.items() {
                this.sp();
                this.open("cap");
                this.name(cap.name);
                match (cap.mode) {
                    .COPY => { this.s(" copy"); },
                    .REF => { this.s(" ref"); },
                    .MOVE => { this.s(" move"); },
                }
                this.span(cap.span);
                this.close();
            }
            this.out.append(" ]");
            this.params(&c.params);
            this.opt_ty(&c.ret);
            this.sp();
            this.block(&c.body);
        },
        .TRY(x) => {
            this.open("try");
            this.expr(x);
        },
        .AWAIT(x) => {
            this.open("await");
            this.expr(x);
        },
        .ASYNC(x) => {
            this.open("async");
            this.expr(x);
        },
        .MOVE(x) => {
            this.open("move");
            this.expr(x);
        },
        .COPY(x) => {
            this.open("copy");
            this.expr(x);
        },
        .CATCH(x, cap, h) => {
            this.open("catch");
            this.expr(x);
            if (cap) {
                this.name(cap.name);
                this.span(cap.span);
            } else {
                this.none();
            }
            this.expr(h);
        },
        .OR_ELSE(a, b) => {
            this.open("orelse");
            this.expr(a);
            this.expr(b);
        },
        .RETURN(x&) => {
            this.open("return");
            this.opt_box(x);
        },
        .BREAK(l, x&) => {
            this.open("break");
            this.opt_name(l);
            this.opt_box(x);
        },
        .CONTINUE(l) => {
            this.open("continue");
            this.opt_name(l);
        },
        .BLOCK(l, b&) => {
            this.open("eblock");
            this.opt_name(l);
            this.sp();
            this.block(b);
        },
        .LOOP(l, b&) => {
            this.open("loop");
            this.opt_name(l);
            this.sp();
            this.block(b);
        },
        .WHILE(l, c, b&) => {
            this.open("while");
            this.opt_name(l);
            this.expr(c);
            this.sp();
            this.block(b);
        },
        .FOR(f&) => {
            this.open("for");
            this.opt_name(f.label);
            this.out.append(" [");
            for (bd&) in f.bindings.items() {
                this.sp();
                this.open("bind");
                this.name(bd.name);
                this.flag(bd.by_ref);
                this.span(bd.span);
                this.close();
            }
            this.out.append(" ]");
            this.expr(&f.iter);
            this.opt_expr(&f.map);
            if (f.acc) {
                this.sp();
                this.let_stmt(&f.acc);
            } else {
                this.none();
            }
            this.sp();
            this.block(&f.body);
            this.flag(f.is_comptime);
        },
        .IF(n&) => {
            this.open("if");
            this.expr(n.cond);
            this.sp();
            this.block(&n.then);
            this.opt_box(&n.els);
            this.flag(n.is_comptime);
        },
        .MATCH(m) => {
            this.open("match");
            this.expr(m.scrut);
            this.out.append(" [");
            for (a&) in m.arms.items() {
                this.sp();
                this.open("arm");
                this.sp();
                this.pat(&a.pat);
                this.opt_expr(&a.guard);
                this.expr(&a.body);
                this.span(a.span);
                this.close();
            }
            this.out.append(" ]");
            this.flag(m.is_comptime);
        },
    }
    this.span(e.span);
    this.close();
}
