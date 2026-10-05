// A canonical text form of the AST (`voltc parse FILE --sexp`). The self-hosted parser prints the
// same form, so the two can be compared byte for byte. Nodes are (Tag fields...), lists [...],
// absent values _, bools t/f, names and strings "..." (bytes outside printable ASCII as \xx),
// spans @lo:hi, floats by their bits.
use crate::ast::*;
use crate::diag::Span;

/// prints nodes in the canonical form into `out`. Most writers put a space before what they write; ty,
/// path, pat, block, let_, fn_decl and item don't, so their callers add one
pub struct W {
    pub out: String,
}

impl W {
    fn s(&mut self, t: &str) {
        self.out.push_str(t);
    }
    fn open(&mut self, tag: &str) {
        self.out.push('(');
        self.out.push_str(tag);
    }
    fn close(&mut self) {
        self.out.push(')');
    }
    fn sp(&mut self) {
        self.out.push(' ');
    }
    fn span(&mut self, s: Span) {
        self.out.push_str(&format!(" @{}:{}", s.lo, s.hi));
    }
    /// a quoted string; bytes outside printable ASCII, `"` and `\` print as \xx
    fn bytes(&mut self, b: &[u8]) {
        self.out.push_str(" \"");
        for &c in b {
            if (0x20..0x7f).contains(&c) && c != b'"' && c != b'\\' {
                self.out.push(c as char);
            } else {
                self.out.push_str(&format!("\\{c:02x}"));
            }
        }
        self.out.push('"');
    }
    fn name(&mut self, n: &str) {
        self.bytes(n.as_bytes());
    }
    fn flag(&mut self, b: bool) {
        self.out.push_str(if b { " t" } else { " f" });
    }
    fn none(&mut self) {
        self.out.push_str(" _");
    }
    /// ` [ ... ]`, with f writing each element
    fn list<T>(&mut self, xs: &[T], f: impl Fn(&mut Self, &T)) {
        self.out.push_str(" [");
        for x in xs {
            f(self, x);
        }
        self.out.push_str(" ]");
    }
    /// the value, or ` _` when absent
    fn opt<T>(&mut self, x: &Option<T>, f: impl Fn(&mut Self, &T)) {
        match x {
            Some(v) => f(self, v),
            None => self.none(),
        }
    }

    // ---------- nodes ----------

    /// one line per top-level item
    pub fn items(&mut self, items: &[Item]) {
        for it in items {
            self.item(it);
            self.out.push('\n');
        }
    }

    fn item(&mut self, it: &Item) {
        self.open("item");
        self.span(it.span);
        self.list(&it.attrs, |w, a| w.expr(a));
        self.list(&it.generics, |w, g| w.generic_param(g));
        self.s(if it.vis == Vis::Internal { " internal" } else { " public" });
        self.sp();
        match &it.kind {
            ItemKind::Fn(f) => self.fn_decl(f),
            ItemKind::Struct(s) => {
                self.open("struct");
                self.name(&s.name);
                self.opt(&s.spec, |w, a| w.list(a, |w, g| w.garg(g)));
                self.list(&s.fields, |w, f| {
                    w.sp();
                    w.open("field");
                    w.name(&f.name);
                    w.sp();
                    w.ty(&f.ty);
                    w.opt(&f.default, |w, e| w.expr(e));
                    w.s(if f.vis == Vis::Internal { " internal" } else { " public" });
                    w.span(f.span);
                    w.list(&f.attrs, |w, a| w.expr(a));
                    w.close();
                });
                self.flag(s.is_extern);
                self.flag(s.is_comptime);
                self.close();
            }
            ItemKind::Enum(e) => {
                self.open("enum");
                self.name(&e.name);
                self.opt(&e.backing, |w, t| {
                    w.sp();
                    w.ty(t)
                });
                self.list(&e.variants, |w, v| {
                    w.sp();
                    w.open("variant");
                    w.name(&v.name);
                    w.opt(&v.payload, |w, t| {
                        w.sp();
                        w.ty(t)
                    });
                    w.opt(&v.value, |w, e| w.expr(e));
                    w.span(v.span);
                    w.close();
                });
                self.flag(e.is_error);
                self.close();
            }
            ItemKind::Trait { name, fns } => {
                self.open("trait");
                self.name(name);
                self.list(fns, |w, i| {
                    w.sp();
                    w.item(i)
                });
                self.close();
            }
            ItemKind::AttachBlock { trait_, target, fns } => {
                self.open("attach");
                self.sp();
                self.ty(trait_);
                self.sp();
                self.ty(target);
                self.list(fns, |w, i| {
                    w.sp();
                    w.item(i)
                });
                self.close();
            }
            ItemKind::Namespace(path, items) => {
                self.open("namespace");
                self.list(path, |w, p| w.name(p));
                self.list(items, |w, i| {
                    w.sp();
                    w.item(i)
                });
                self.close();
            }
            ItemKind::Use(p) => {
                self.open("use");
                self.sp();
                self.path(p);
                self.close();
            }
            ItemKind::UseC { headers, alias } | ItemKind::UseCpp { headers, alias } => {
                self.open(if matches!(it.kind, ItemKind::UseCpp { .. }) { "usecpp" } else { "usec" });
                self.list(headers, |w, h| w.name(h));
                self.name(alias);
                self.close();
            }
            ItemKind::UseLang { lang, args, alias } => {
                self.open("uselang");
                self.name(lang);
                self.list(args, |w, h| w.name(h));
                self.name(alias);
                self.close();
            }
            ItemKind::Global(l) => {
                self.open("global");
                self.sp();
                self.let_(l);
                self.close();
            }
            // `type name = T;`, and C imports' typedefs
            ItemKind::Alias(n, t) => {
                self.open("alias");
                self.name(n);
                self.sp();
                self.ty(t);
                self.close();
            }
            ItemKind::Emit(e) => {
                self.open("emit");
                self.expr(e);
                self.close();
            }
        }
        self.close();
    }

    fn fn_decl(&mut self, f: &FnDecl) {
        self.open("fn");
        self.name(&f.name);
        self.opt(&f.spec, |w, a| w.list(a, |w, g| w.garg(g)));
        self.list(&f.params, |w, p| w.param(p));
        self.flag(f.c_varargs);
        self.opt(&f.ret, |w, t| {
            w.sp();
            w.ty(t)
        });
        self.opt(&f.body, |w, b| {
            w.sp();
            w.block(b)
        });
        self.flag(f.is_async);
        self.flag(f.is_comptime);
        self.opt(&f.extern_abi, |w, a| w.name(a));
        self.flag(f.is_export);
        self.flag(f.is_attach);
        self.close();
    }

    fn param(&mut self, p: &Param) {
        self.sp();
        self.open("param");
        self.name(&p.name);
        self.opt(&p.ty, |w, t| {
            w.sp();
            w.ty(t)
        });
        self.opt(&p.default, |w, e| w.expr(e));
        self.flag(p.mutable);
        self.flag(p.is_static);
        self.flag(p.comptime);
        self.span(p.span);
        self.close();
    }

    fn generic_param(&mut self, g: &GenericParam) {
        self.sp();
        self.open("gparam");
        self.name(&g.name);
        self.list(&g.bounds, |w, t| {
            w.sp();
            w.ty(t)
        });
        self.flag(g.pack);
        self.opt(&g.default, |w, a| w.garg(a));
        self.span(g.span);
        self.close();
    }

    fn garg(&mut self, g: &GenericArg) {
        self.sp();
        match g {
            GenericArg::Type(t) => {
                self.open("gtype");
                self.sp();
                self.ty(t);
            }
            GenericArg::Expr(e) => {
                self.open("gexpr");
                self.expr(e);
            }
        }
        self.close();
    }

    fn path(&mut self, p: &Path) {
        self.open("path");
        self.list(&p.segs, |w, s| {
            w.sp();
            w.open("seg");
            w.name(&s.name);
            w.opt(&s.args, |w, a| w.list(a, |w, g| w.garg(g)));
            w.close();
        });
        self.span(p.span);
        self.close();
    }

    pub fn ty(&mut self, t: &Type) {
        let bx = |w: &mut Self, t: &Type| {
            w.sp();
            w.ty(t)
        };
        match &t.kind {
            TypeKind::Path(p) => {
                self.open("tpath");
                self.sp();
                self.path(p);
            }
            TypeKind::Ref(i) => {
                self.open("tref");
                bx(self, i);
            }
            TypeKind::Ptr(i) => {
                self.open("tptr");
                bx(self, i);
            }
            TypeKind::Optional(i) => {
                self.open("topt");
                bx(self, i);
            }
            TypeKind::Array(i, n) => {
                self.open("tarray");
                bx(self, i);
                self.opt(n, |w, e| w.expr(e));
            }
            TypeKind::Slice(i) => {
                self.open("tslice");
                bx(self, i);
            }
            TypeKind::Tuple(es) => {
                self.open("ttuple");
                self.list(es, |w, (n, t)| {
                    w.opt(n, |w, n| w.name(n));
                    w.sp();
                    w.ty(t);
                });
            }
            TypeKind::ErrorUnion(e, t) => {
                self.open("terr");
                self.opt(e, |w, t| bx(w, t));
                bx(self, t);
            }
            TypeKind::Fn { params, c_varargs, ret, extern_c } => {
                self.open("tfn");
                self.list(params, |w, t| bx(w, t));
                self.flag(*c_varargs);
                bx(self, ret);
                self.flag(*extern_c);
            }
            TypeKind::Pack(i) => {
                self.open("tpack");
                bx(self, i);
            }
            TypeKind::Expr(e) => {
                self.open("texpr");
                self.expr(e);
            }
        }
        self.span(t.span);
        self.close();
    }

    fn block(&mut self, b: &Block) {
        self.open("block");
        self.list(&b.stmts, |w, s| w.stmt(s));
        self.span(b.span);
        self.close();
    }

    fn let_(&mut self, l: &Let) {
        self.open("let");
        self.flag(l.mutable);
        self.flag(l.comptime);
        self.flag(l.is_static);
        self.sp();
        self.pat(&l.pat);
        self.opt(&l.ty, |w, t| {
            w.sp();
            w.ty(t)
        });
        self.opt(&l.init, |w, e| w.expr(e));
        self.span(l.span);
        self.close();
    }

    fn stmt(&mut self, s: &Stmt) {
        self.sp();
        match &s.kind {
            StmtKind::Let(l) => self.let_(l),
            StmtKind::Expr(e) => {
                self.open("sexpr");
                self.expr(e);
                self.close();
            }
            StmtKind::Defer(e) => {
                self.open("defer");
                self.expr(e);
                self.close();
            }
            StmtKind::ErrDefer(e) => {
                self.open("errdefer");
                self.expr(e);
                self.close();
            }
            StmtKind::Suspend => self.s("(suspend)"),
            StmtKind::Resume(e) => {
                self.open("resume");
                self.expr(e);
                self.close();
            }
        }
        self.span(s.span);
    }

    fn pat(&mut self, p: &Pat) {
        match &p.kind {
            PatKind::Wild => self.open("pwild"),
            PatKind::Bind(n) => {
                self.open("pbind");
                self.name(n);
            }
            PatKind::BindRef(n) => {
                self.open("pbindref");
                self.name(n);
            }
            PatKind::Lit(e) => {
                self.open("plit");
                self.expr(e);
            }
            PatKind::Range(a, b, incl) => {
                self.open("prange");
                self.expr(a);
                self.expr(b);
                self.flag(*incl);
            }
            PatKind::Ctor(c, args) => {
                self.open("pctor");
                match c {
                    CtorPath::Dot(n) => {
                        self.s(" dot");
                        self.name(n);
                    }
                    CtorPath::Path(p) => {
                        self.sp();
                        self.path(p);
                    }
                }
                self.opt(args, |w, a| {
                    w.list(a, |w, p| {
                        w.sp();
                        w.pat(p)
                    })
                });
            }
            PatKind::Tuple(ps) => {
                self.open("ptuple");
                self.list(ps, |w, p| {
                    w.sp();
                    w.pat(p)
                });
            }
            PatKind::Slice(ps, rest) => {
                self.open("pslice");
                self.list(ps, |w, p| {
                    w.sp();
                    w.pat(p)
                });
                self.opt(rest, |w, (at, name)| {
                    w.s(&format!(" {at}"));
                    w.opt(name, |w, (n, _)| w.name(n));
                });
            }
        }
        self.span(p.span);
        self.close();
    }

    pub fn expr(&mut self, e: &Expr) {
        self.sp();
        let bin = |op: BinOp| match op {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
            BinOp::WAdd => "+%",
            BinOp::WSub => "-%",
            BinOp::WMul => "*%",
            BinOp::And => "&&",
            BinOp::Or => "||",
            BinOp::BitAnd => "&",
            BinOp::BitOr => "|",
            BinOp::BitXor => "^",
            BinOp::Shl => "<<",
            BinOp::Shr => ">>",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::Lt => "<",
            BinOp::Gt => ">",
            BinOp::Le => "<=",
            BinOp::Ge => ">=",
        };
        match &e.kind {
            ExprKind::Int(v) => self.s(&format!("(int {v}")),
            ExprKind::Float(v) => self.s(&format!("(float {:016x}", v.to_bits())),
            ExprKind::Char(v) => self.s(&format!("(char {v}")),
            ExprKind::Str(s) => {
                self.open("str");
                self.bytes(s);
            }
            ExprKind::Bool(b) => self.s(if *b { "(true" } else { "(false" }),
            ExprKind::Null => self.open("null"),
            ExprKind::This => self.open("this"),
            ExprKind::ErrorAny => self.open("errorany"),
            ExprKind::Path(p) => {
                self.open("epath");
                self.sp();
                self.path(p);
            }
            ExprKind::DotVariant(n) => {
                self.open("dotvariant");
                self.name(n);
            }
            ExprKind::Unary(op, x) => {
                self.open("unary");
                self.s(match op {
                    UnOp::Neg => " -",
                    UnOp::Not => " !",
                    UnOp::BitNot => " ~",
                    UnOp::Addr => " &",
                    UnOp::Deref => " *",
                });
                self.expr(x);
            }
            ExprKind::Binary(op, a, b) => {
                self.open("binary");
                self.sp();
                self.s(bin(*op));
                self.expr(a);
                self.expr(b);
            }
            ExprKind::Assign(op, a, b) => {
                self.open("assign");
                match op {
                    Some(op) => {
                        self.sp();
                        self.s(bin(*op));
                    }
                    None => self.none(),
                }
                self.expr(a);
                self.expr(b);
            }
            ExprKind::IncDec(x, inc) => {
                self.open("incdec");
                self.expr(x);
                self.flag(*inc);
            }
            ExprKind::Cast(x, t) => {
                self.open("cast");
                self.expr(x);
                self.sp();
                self.ty(t);
            }
            ExprKind::Range(a, b, incl) => {
                self.open("range");
                self.opt(a, |w, x| w.expr(x));
                self.opt(b, |w, x| w.expr(x));
                self.flag(*incl);
            }
            ExprKind::Call(f, args) => {
                self.open("call");
                self.expr(f);
                self.list(args, |w, a| w.expr(a));
            }
            ExprKind::Field(x, n, args) => {
                self.open("field");
                self.expr(x);
                self.name(n);
                self.opt(args, |w, a| w.list(a, |w, g| w.garg(g)));
            }
            ExprKind::Index(x, i) => {
                self.open("index");
                self.expr(x);
                self.expr(i);
            }
            ExprKind::Builtin(n, gargs, args) => {
                self.open("builtin");
                self.name(n);
                self.list(gargs, |w, g| w.garg(g));
                self.opt(args, |w, a| w.list(a, |w, g| w.garg(g)));
            }
            ExprKind::Tuple(es) => {
                self.open("tuple");
                self.list(es, |w, x| w.expr(x));
            }
            ExprKind::Repeat(x, n) => {
                self.open("repeat");
                self.expr(x);
                self.expr(n);
            }
            ExprKind::Literal(es) => {
                self.open("literal");
                self.list(es, |w, (n, x)| {
                    w.opt(n, |w, n| w.name(n));
                    w.expr(x);
                });
            }
            ExprKind::Closure { caps, generics, params, ret, body } => {
                self.open("closure");
                self.list(caps, |w, c| {
                    w.sp();
                    w.open("cap");
                    w.name(&c.name);
                    w.s(match c.mode {
                        CapMode::Copy => " copy",
                        CapMode::Ref => " ref",
                        CapMode::Move => " move",
                    });
                    w.span(c.span);
                    w.close();
                });
                self.list(generics, |w, g| w.generic_param(g));
                self.list(params, |w, p| w.param(p));
                self.opt(ret, |w, t| {
                    w.sp();
                    w.ty(t)
                });
                self.sp();
                self.block(body);
            }
            ExprKind::Try(x) => {
                self.open("try");
                self.expr(x);
            }
            ExprKind::Await(x) => {
                self.open("await");
                self.expr(x);
            }
            ExprKind::Async(x) => {
                self.open("async");
                self.expr(x);
            }
            ExprKind::Quote(parts) => {
                self.open("quote");
                for p in parts {
                    match p {
                        QuotePart::Text(t) => self.bytes(t.as_bytes()),
                        QuotePart::Splice(e) => self.expr(e),
                    }
                }
            }
            ExprKind::Move(x) => {
                self.open("move");
                self.expr(x);
            }
            ExprKind::Copy(x) => {
                self.open("copy");
                self.expr(x);
            }
            ExprKind::Catch(x, cap, h) => {
                self.open("catch");
                self.expr(x);
                self.opt(cap, |w, (n, s)| {
                    w.name(n);
                    w.span(*s);
                });
                self.expr(h);
            }
            ExprKind::OrElse(a, b) => {
                self.open("orelse");
                self.expr(a);
                self.expr(b);
            }
            ExprKind::Return(x) => {
                self.open("return");
                self.opt(x, |w, x| w.expr(x));
            }
            ExprKind::Break(l, x) => {
                self.open("break");
                self.opt(l, |w, l| w.name(l));
                self.opt(x, |w, x| w.expr(x));
            }
            ExprKind::Continue(l) => {
                self.open("continue");
                self.opt(l, |w, l| w.name(l));
            }
            ExprKind::Block(l, b) => {
                self.open("eblock");
                self.opt(l, |w, l| w.name(l));
                self.sp();
                self.block(b);
            }
            ExprKind::Loop(l, b) => {
                self.open("loop");
                self.opt(l, |w, l| w.name(l));
                self.sp();
                self.block(b);
            }
            ExprKind::While(l, c, b) => {
                self.open("while");
                self.opt(l, |w, l| w.name(l));
                self.expr(c);
                self.sp();
                self.block(b);
            }
            ExprKind::For(f) => {
                self.open("for");
                self.opt(&f.label, |w, l| w.name(l));
                self.list(&f.bindings, |w, (n, r, s)| {
                    w.sp();
                    w.open("bind");
                    w.name(n);
                    w.flag(*r);
                    w.span(*s);
                    w.close();
                });
                self.expr(&f.iter);
                self.opt(&f.map, |w, x| w.expr(x));
                self.opt(&f.acc, |w, l| {
                    w.sp();
                    w.let_(l)
                });
                self.sp();
                self.block(&f.body);
                self.flag(f.comptime);
            }
            ExprKind::If { cond, then, els, comptime } => {
                self.open("if");
                self.expr(cond);
                self.sp();
                self.block(then);
                self.opt(els, |w, x| w.expr(x));
                self.flag(*comptime);
            }
            ExprKind::Match { scrut, arms, comptime } => {
                self.open("match");
                self.expr(scrut);
                self.list(arms, |w, a| {
                    w.sp();
                    w.open("arm");
                    w.sp();
                    w.pat(&a.pat);
                    w.opt(&a.guard, |w, g| w.expr(g));
                    w.expr(&a.body);
                    w.span(a.span);
                    w.close();
                });
                self.flag(*comptime);
            }
        }
        self.span(e.span);
        self.close();
    }
}
