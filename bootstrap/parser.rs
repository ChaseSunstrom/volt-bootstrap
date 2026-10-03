// Recursive descent + precedence climbing.
// `f<T>(...)` in expressions is a generic call only when f names a generic (collected by a token scan
// of every file first), otherwise `<` is less-than.
use crate::ast::*;
use crate::diag::{Diag, Res, Span, err};
use crate::lexer::{Tok, Token};
use std::collections::HashSet;

/// words that are never a name (`ident` rejects them); `error` still starts a path (`error::X`)
const KEYWORDS: &[&str] = &[
    "var", "val", "static", "public", "internal", "attach", "struct", "enum", "fn", "error", "trait", "comptime",
    "async", "await", "suspend", "resume", "extern", "export", "namespace", "use", "as", "this", "move", "copy",
    "if", "else", "for", "in", "while", "loop", "break", "continue", "return", "match", "default", "try", "catch",
    "defer", "errdefer", "true", "false", "null",
];

// builtins that take <generic> args
const GENERIC_BUILTINS: &[&str] = &["cast", "bitcast", "cpp"];

/// Names declared with a generic prefix: `<...> [modifiers] fn|struct|enum|trait|error|type NAME`.
pub fn collect_generic_names(toks: &[Token], out: &mut HashSet<String>) {
    let ident = |j: usize| match toks.get(j).map(|t| &t.tok) {
        Some(Tok::Ident(s)) => Some(s.as_str()),
        _ => None,
    };
    for i in 0..toks.len() {
        if toks[i].tok != Tok::Punct(">") {
            continue;
        }
        let mut j = i + 1;
        loop {
            match ident(j) {
                Some("public" | "internal" | "comptime" | "async" | "export" | "attach" | "static") => j += 1,
                Some("extern") => {
                    j += 1;
                    if matches!(toks.get(j).map(|t| &t.tok), Some(Tok::Str(_))) {
                        j += 1;
                    }
                }
                _ => {
                    // @attributes([...]) between the generics and the declaration: past its parens
                    if !matches!(toks.get(j).map(|t| &t.tok), Some(Tok::Builtin(s)) if s == "attributes") {
                        break;
                    }
                    j += 1;
                    let mut depth = 0;
                    while let Some(t) = toks.get(j) {
                        j += 1;
                        match &t.tok {
                            Tok::Punct("(") => depth += 1,
                            Tok::Punct(")") => {
                                depth -= 1;
                                if depth == 0 {
                                    break;
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
        if let Some("fn" | "struct" | "enum" | "trait" | "error" | "type") = ident(j) {
            if let Some(name) = ident(j + 1) {
                out.insert(name.to_string());
            }
        }
    }
}

/// parses one file's tokens; `generics` is every generic name in the program (collect_generic_names)
pub struct Parser<'a> {
    toks: &'a [Token],
    pos: usize,
    generics: &'a HashSet<String>,
    src: &'a str,
    errors: Vec<Diag>, // one per broken item (see items)
    item_col: usize,   // the column the current item starts at
    // a block whose '}' didn't line up with the line that opened it, in the current item: the
    // likely culprit when a block turns out never closed
    suspect: Option<(Span, Span)>,
}

/// an infix operator as `infix` sees it; `bin` gives each kind its own parse
#[derive(Clone, Copy)]
enum Infix {
    Bin(BinOp, usize), // op, tokens to consume
    OrElse,
    Catch,
    Range(bool),
    As,
}

// precedences used outside the table in `infix` (higher binds tighter)
const PREC_ORELSE: u8 = 1;
const PREC_RANGE: u8 = 2;
/// the lowest level a generic arg's expression parses at, so a `>` there closes the list
const PREC_BITOR: u8 = 6;

impl<'a> Parser<'a> {
    pub fn new(toks: &'a [Token], generics: &'a HashSet<String>, src: &'a str) -> Self {
        Parser { toks, pos: 0, generics, src, errors: Vec::new(), item_col: 0, suspect: None }
    }

    // ---------- token helpers ----------

    fn tok(&self) -> &Tok {
        &self.toks[self.pos].tok
    }
    /// the token n ahead; past the end it's the final Eof
    fn tok_at(&self, n: usize) -> &Tok {
        &self.toks[(self.pos + n).min(self.toks.len() - 1)].tok
    }
    fn span(&self) -> Span {
        self.toks[self.pos].span
    }
    fn prev_span(&self) -> Span {
        self.toks[self.pos.saturating_sub(1)].span
    }
    /// whether the token n ahead has no whitespace before it
    fn glued_at(&self, n: usize) -> bool {
        self.toks.get(self.pos + n).is_some_and(|t| t.glued)
    }
    /// returns the current token and moves on; never moves past the final Eof
    fn bump(&mut self) -> Token {
        let t = self.toks[self.pos].clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        t
    }
    fn at_eof(&self) -> bool {
        *self.tok() == Tok::Eof
    }
    fn is(&self, p: &str) -> bool {
        matches!(self.tok(), Tok::Punct(q) if *q == p)
    }
    fn is_at(&self, n: usize, p: &str) -> bool {
        matches!(self.tok_at(n), Tok::Punct(q) if *q == p)
    }
    fn eat(&mut self, p: &str) -> bool {
        if self.is(p) {
            self.bump();
            true
        } else {
            false
        }
    }
    fn expect(&mut self, p: &str) -> Res<Span> {
        if self.is(p) {
            Ok(self.bump().span)
        } else {
            self.unexpected(&format!("'{p}'"))
        }
    }
    fn is_kw(&self, k: &str) -> bool {
        matches!(self.tok(), Tok::Ident(s) if s == k)
    }
    fn is_kw_at(&self, n: usize, k: &str) -> bool {
        matches!(self.tok_at(n), Tok::Ident(s) if s == k)
    }
    fn eat_kw(&mut self, k: &str) -> bool {
        if self.is_kw(k) {
            self.bump();
            true
        } else {
            false
        }
    }
    fn expect_kw(&mut self, k: &str) -> Res<Span> {
        if self.is_kw(k) {
            Ok(self.bump().span)
        } else {
            self.unexpected(&format!("'{k}'"))
        }
    }
    /// the `expected X, found Y` error at the current token
    fn unexpected<T>(&self, what: &str) -> Res<T> {
        let found = match self.tok() {
            Tok::Ident(s) => format!("'{s}'"),
            Tok::Int(v) => format!("number {v}"),
            Tok::Float(v) => format!("number {v}"),
            Tok::Char(_) => "char literal".into(),
            Tok::Str(_) => "string".into(),
            Tok::Builtin(s) => format!("'@{s}'"),
            Tok::Punct(p) => format!("'{p}'"),
            Tok::Eof => "end of file".into(),
        };
        err(self.span(), format!("expected {what}, found {found}"))
    }
    /// a name that isn't a keyword
    fn ident(&mut self) -> Res<(String, Span)> {
        match self.tok() {
            Tok::Ident(s) if !KEYWORDS.contains(&s.as_str()) => {
                let s = s.clone();
                Ok((s, self.bump().span))
            }
            _ => self.unexpected("a name"),
        }
    }
    fn is_ident(&self) -> bool {
        matches!(self.tok(), Tok::Ident(s) if !KEYWORDS.contains(&s.as_str()))
    }
    fn is_ident_at(&self, n: usize) -> bool {
        matches!(self.tok_at(n), Tok::Ident(s) if !KEYWORDS.contains(&s.as_str()))
    }
    fn expect_gt(&mut self) -> Res<()> {
        self.expect(">").map(|_| ())
    }

    // ---------- items ----------

    pub fn parse_file(&mut self) -> Result<Vec<Item>, Vec<Diag>> {
        let items = self.items(false);
        if self.errors.is_empty() {
            Ok(items)
        } else {
            Err(std::mem::take(&mut self.errors))
        }
    }

    /// items up to the end of the file, or up to `}` in a block. An item with an error is recorded
    /// and skipped, so one run reports every broken item
    fn items(&mut self, in_block: bool) -> Vec<Item> {
        let mut items = Vec::new();
        while !self.at_eof() && !(in_block && self.is("}")) {
            let start = self.pos;
            self.item_col = self.line_col(start).unwrap_or(0);
            self.suspect = None;
            match self.item() {
                Ok(it) => items.push(it),
                Err(d) => {
                    self.errors.push(d);
                    self.resync(start);
                }
            }
        }
        items
    }

    /// after an error in the item starting at token `start`: skip to the next line that starts at
    /// that item's column with something that starts an item, or further left (the enclosing
    /// block's `}`). Indentation is the guide, since the error may be an unbalanced brace
    fn resync(&mut self, start: usize) {
        let col = self.line_col(start).unwrap_or(0);
        if self.pos <= start {
            self.bump();
        }
        while !self.at_eof() {
            if let Some(c) = self.line_col(self.pos) {
                if c < col || (c == col && self.starts_item()) {
                    return;
                }
            }
            self.bump();
        }
    }

    /// token i's column, when it's the first on its line
    fn line_col(&self, i: usize) -> Option<usize> {
        let lo = self.toks[i].span.lo as usize;
        let line = self.src[..lo].rfind('\n').map_or(0, |n| n + 1);
        self.src.as_bytes()[line..lo].iter().all(|&b| b == b' ' || b == b'\t').then_some(lo - line)
    }

    fn starts_item(&self) -> bool {
        const STARTS: &[&str] = &[
            "fn", "struct", "enum", "error", "trait", "attach", "use", "namespace", "val", "var", "static", "internal",
            "public", "async", "comptime", "export", "extern",
        ];
        matches!(self.tok(), Tok::Builtin(_)) || self.is("<") || STARTS.iter().any(|k| self.is_kw(k))
    }

    /// one declaration. Order: @attributes and `<generic params>`, visibility, modifiers (async comptime
    /// export attach extern "abi"), then the keyword that says what it is
    fn item(&mut self) -> Res<Item> {
        let start = self.span();
        let mut attrs = Vec::new();
        let mut generics = Vec::new();
        loop {
            if matches!(self.tok(), Tok::Builtin(s) if s == "attributes") {
                attrs.extend(self.attributes()?);
            } else if self.is("<") {
                generics = self.generic_params()?;
            } else {
                break;
            }
        }
        let vis = if self.eat_kw("internal") {
            Vis::Internal
        } else {
            self.eat_kw("public");
            Vis::Public
        };
        let (mut is_async, mut is_comptime, mut is_export, mut is_attach, mut is_extern) = (false, false, false, false, false);
        let mut abi = None;
        loop {
            if self.eat_kw("async") {
                is_async = true;
            } else if self.eat_kw("comptime") {
                is_comptime = true;
            } else if self.eat_kw("export") {
                is_export = true;
            } else if self.eat_kw("attach") {
                is_attach = true;
            } else if self.eat_kw("extern") {
                is_extern = true;
                if let Tok::Str(s) = self.tok() {
                    abi = Some(String::from_utf8_lossy(s).into_owned());
                    self.bump();
                }
            } else {
                break;
            }
        }
        // the modifiers came before we knew what they modify: a fn takes them all, a struct only
        // extern/comptime, a global comptime; anything else ignores them
        let kind = if self.eat_kw("fn") {
            let mut f = self.fn_decl()?;
            f.is_async = is_async;
            f.is_comptime = is_comptime;
            f.is_export = is_export;
            f.is_attach = is_attach;
            f.extern_abi = if is_extern { Some(abi.unwrap_or_else(|| "C".into())) } else { None };
            ItemKind::Fn(f)
        } else if is_attach {
            // `attach Trait -> Target { fns }`: an attach block, since no `fn` followed
            let trait_ = self.parse_type()?;
            self.expect("->")?;
            let target = self.parse_type()?;
            ItemKind::AttachBlock { trait_, target, fns: self.item_block()? }
        } else if self.eat_kw("struct") {
            let (name, _) = self.ident()?;
            let spec = if self.is("<") { Some(self.generic_args()?) } else { None };
            let mut fields = Vec::new();
            if !self.eat(";") {
                self.expect("{")?;
                while !self.eat("}") {
                    let fstart = self.span();
                    let fvis = if self.eat_kw("internal") {
                        Vis::Internal
                    } else {
                        self.eat_kw("public");
                        Vis::Public
                    };
                    let (fname, _) = self.ident()?;
                    self.expect(":")?;
                    let ty = self.parse_type()?;
                    let default = if self.eat("=") { Some(self.expr()?) } else { None };
                    if !self.eat(";") && !self.eat(",") && !self.is("}") {
                        return self.unexpected("';' after field");
                    }
                    fields.push(Field { name: fname, ty, default, vis: fvis, span: fstart.to(self.prev_span()) });
                }
            }
            ItemKind::Struct(StructDecl { name, spec, fields, is_extern, is_comptime, c_name: None, c_union: false })
        } else if self.is_kw("enum") || self.is_kw("error") {
            let is_error = self.bump().tok == Tok::Ident("error".into());
            let (name, _) = self.ident()?;
            let backing = if !is_error && self.eat(":") { Some(self.parse_type()?) } else { None };
            self.expect("{")?;
            let mut variants = Vec::new();
            while !self.eat("}") {
                let vstart = self.span();
                let (vname, _) = self.ident()?;
                let payload = if self.eat(":") { Some(self.parse_type()?) } else { None };
                let value = if self.eat("=") { Some(self.expr()?) } else { None };
                variants.push(Variant { name: vname, payload, value, span: vstart.to(self.prev_span()) });
                if !self.eat(",") && !self.is("}") {
                    return self.unexpected("',' or '}'");
                }
            }
            ItemKind::Enum(EnumDecl { name, backing, variants, is_error })
        } else if self.is_kw("type") && matches!(self.tok_at(1), Tok::Ident(_)) && matches!(self.tok_at(2), Tok::Punct("=")) {
            // `type name = T;`: another name for a type (`<T: type> type list = std::vec<T>;`)
            self.bump();
            let (name, _) = self.ident()?;
            self.expect("=")?;
            let ty = self.parse_type()?;
            self.expect(";")?;
            ItemKind::Alias(name, ty)
        } else if self.eat_kw("trait") {
            let (name, _) = self.ident()?;
            ItemKind::Trait { name, fns: self.item_block()? }
        } else if self.eat_kw("namespace") {
            let mut path = vec![self.ident()?.0];
            while self.eat("::") {
                path.push(self.ident()?.0);
            }
            ItemKind::Namespace(path, self.item_block()?)
        } else if self.eat_kw("use") {
            // `use cpp { ... }`: C++ headers (`use cpp::x;` is still a path)
            let cpp = matches!(self.tok(), Tok::Ident(n) if n == "cpp") && matches!(self.tok_at(1), Tok::Punct("{"));
            // `use rust { ... }` and the like: code in another language
            let lang = match (self.tok(), self.tok_at(1)) {
                (Tok::Ident(n), Tok::Punct("{")) if n != "cpp" => Some(n.clone()),
                _ => None,
            };
            if cpp || lang.is_some() {
                self.bump();
            }
            if self.eat("{") {
                let mut headers = Vec::new();
                while !self.eat("}") {
                    match self.tok().clone() {
                        Tok::Str(s) => {
                            self.bump();
                            headers.push(String::from_utf8_lossy(&s).into_owned());
                        }
                        _ => return self.unexpected(if lang.is_some() { "a string" } else { "a header name string" }),
                    }
                    if !self.eat(",") && !self.is("}") {
                        return self.unexpected("',' or '}'");
                    }
                }
                self.expect_kw("as")?;
                let (alias, _) = self.ident()?;
                self.expect(";")?;
                match lang {
                    Some(lang) => ItemKind::UseLang { lang, args: headers, alias },
                    None if cpp => ItemKind::UseCpp { headers, alias },
                    None => ItemKind::UseC { headers, alias },
                }
            } else {
                let p = self.path(false)?;
                self.expect(";")?;
                ItemKind::Use(p)
            }
        } else if self.is_kw("var") || self.is_kw("val") || self.is_kw("static") {
            ItemKind::Global(self.let_stmt(is_comptime)?)
        } else {
            return self.unexpected("an item (fn, struct, enum, error, trait, type, attach, namespace, use, var, val)");
        };
        Ok(Item { kind, span: start.to(self.prev_span()), attrs, vis, generics })
    }

    fn item_block(&mut self) -> Res<Vec<Item>> {
        self.expect("{")?;
        let items = self.items(true);
        if !self.eat("}") {
            return self.unexpected("'}'");
        }
        Ok(items)
    }

    // @attributes([@inline, @opt(3)])
    fn attributes(&mut self) -> Res<Vec<Expr>> {
        self.bump();
        self.expect("(")?;
        self.expect("[")?;
        let mut out = Vec::new();
        while !self.eat("]") {
            if !matches!(self.tok(), Tok::Builtin(_)) {
                return self.unexpected("an attribute like @inline");
            }
            out.push(self.builtin()?);
            if !self.eat(",") && !self.is("]") {
                return self.unexpected("',' or ']'");
            }
        }
        self.expect(")")?;
        Ok(out)
    }

    /// `<T: type, N: usize = 4, Args: type...>`; `+` joins bounds, and a `...` bound makes the param a pack
    fn generic_params(&mut self) -> Res<Vec<GenericParam>> {
        self.expect("<")?;
        let mut out = Vec::new();
        while !self.is(">") {
            let start = self.span();
            let (name, _) = self.ident()?;
            let mut bounds = Vec::new();
            let mut pack = false;
            if self.eat(":") {
                loop {
                    let t = self.parse_type()?;
                    match t.kind {
                        TypeKind::Pack(inner) => {
                            pack = true;
                            bounds.push(*inner);
                        }
                        _ => bounds.push(t),
                    }
                    if !self.eat("+") {
                        break;
                    }
                }
            }
            let default = if self.eat("=") { Some(self.generic_arg(">")?) } else { None };
            out.push(GenericParam { name, bounds, pack, default, span: start.to(self.prev_span()) });
            if !self.eat(",") && !self.is(">") {
                return self.unexpected("',' or '>'");
            }
        }
        self.expect_gt()?;
        Ok(out)
    }

    /// `<...>` after a name that is generic somewhere, in an expression: if it doesn't parse as
    /// generic args, it was a less-than (a local that shares the name: `free < cap`)
    fn try_generic_args(&mut self) -> Option<Vec<GenericArg>> {
        let save = self.pos;
        match self.generic_args() {
            Ok(a) => Some(a),
            Err(_) => {
                self.pos = save;
                None
            }
        }
    }

    /// `.name<...>`'s generic args: a name the program declares generic takes them; any other only
    /// when a call follows (`x.get<i32>()`: a method declared where the program's names aren't
    /// collected, like an import's), with one argument or none passed (`f(a.x < b, c > (d))` is two
    /// comparisons)
    fn method_generic_args(&mut self, name: &str) -> Option<Vec<GenericArg>> {
        if !self.is("<") {
            return None;
        }
        if self.generics.contains(name) {
            return self.try_generic_args();
        }
        let save = self.pos;
        match self.try_generic_args() {
            Some(a) if self.is("(") && (a.len() == 1 || self.is_at(1, ")")) => Some(a),
            _ => {
                self.pos = save;
                None
            }
        }
    }

    fn generic_args(&mut self) -> Res<Vec<GenericArg>> {
        self.expect("<")?;
        let mut out = Vec::new();
        while !self.is(">") {
            out.push(self.generic_arg(">")?);
            if !self.eat(",") && !self.is(">") {
                return self.unexpected("',' or '>'");
            }
        }
        self.expect_gt()?;
        Ok(out)
    }

    /// A type if one parses cleanly up to `,`/closer, else an expression.
    fn generic_arg(&mut self, closer: &str) -> Res<GenericArg> {
        let save = self.pos;
        if let Ok(t) = self.parse_type() {
            if self.is(",") || self.is(closer) {
                return Ok(GenericArg::Type(t));
            }
        }
        self.pos = save;
        let e = if closer == ">" { self.bin(PREC_BITOR)? } else { self.expr()? };
        Ok(GenericArg::Expr(e))
    }

    /// the part after `fn`; `item` fills in the modifiers
    fn fn_decl(&mut self) -> Res<FnDecl> {
        // `copy` is a keyword but also the name of the copy hook: attach fn copy(this: T&) -> T
        let name = if self.eat_kw("copy") { "copy".to_string() } else { self.ident()?.0 };
        let spec = if self.is("<") { Some(self.generic_args()?) } else { None };
        let (params, c_varargs) = self.params()?;
        let ret = if self.eat("->") { Some(self.parse_type()?) } else { None };
        let body = if self.eat(";") { None } else { Some(self.block()?) };
        Ok(FnDecl {
            name,
            spec,
            params,
            c_varargs,
            ret,
            body,
            is_async: false,
            is_comptime: false,
            extern_abi: None,
            is_export: false,
            is_attach: false,
        })
    }

    /// `(var x: T = d, static this, ...)`: the params, and whether they end in C varargs `...`
    fn params(&mut self) -> Res<(Vec<Param>, bool)> {
        self.expect("(")?;
        let mut out = Vec::new();
        let mut c_varargs = false;
        while !self.eat(")") {
            if self.eat("...") {
                c_varargs = true;
                self.expect(")")?;
                break;
            }
            let start = self.span();
            let (mut mutable, mut is_static, mut comptime) = (false, false, false);
            loop {
                if self.eat_kw("var") {
                    mutable = true;
                } else if self.eat_kw("static") {
                    is_static = true;
                } else if self.eat_kw("comptime") {
                    comptime = true;
                } else {
                    break;
                }
            }
            let name = if self.eat_kw("this") { "this".to_string() } else { self.ident()?.0 };
            let ty = if self.eat(":") { Some(self.parse_type()?) } else { None };
            let default = if self.eat("=") { Some(self.expr()?) } else { None };
            out.push(Param { name, ty, default, mutable, is_static, comptime, span: start.to(self.prev_span()) });
            if !self.eat(",") && !self.is(")") {
                return self.unexpected("',' or ')'");
            }
        }
        Ok((out, c_varargs))
    }

    // ---------- types ----------

    /// a type. Suffixes after E!T (& * ? [N] [..]) apply to the whole error union: E!T& is a
    /// reference to one, and the payload takes suffixes only in parentheses, E!(T&)
    pub fn parse_type(&mut self) -> Res<Type> {
        let start = self.span();
        let u = if self.eat("!") {
            let inner = self.err_payload()?;
            Type { span: start.to(inner.span), kind: TypeKind::ErrorUnion(None, Box::new(inner)) }
        } else {
            let t = self.type_no_err()?;
            if !self.eat("!") {
                return Ok(t);
            }
            let rhs = self.err_payload()?;
            Type { span: start.to(rhs.span), kind: TypeKind::ErrorUnion(Some(Box::new(t)), Box::new(rhs)) }
        };
        self.type_suffixes(u, start, false)
    }

    /// the T of E!T: no suffixes of its own; E!F!T nests to the right
    fn err_payload(&mut self) -> Res<Type> {
        let start = self.span();
        let a = self.type_atom()?;
        if !self.eat("!") {
            return Ok(a);
        }
        let rhs = self.err_payload()?;
        Ok(Type { span: start.to(rhs.span), kind: TypeKind::ErrorUnion(Some(Box::new(a)), Box::new(rhs)) })
    }

    fn type_no_err(&mut self) -> Res<Type> {
        self.type_core(false)
    }

    /// in_cast: `x as T * 2` multiplies, so after `as` a `*`/`&` is only a suffix when no operand follows
    fn type_core(&mut self, in_cast: bool) -> Res<Type> {
        let start = self.span();
        let a = self.type_atom()?;
        self.type_suffixes(a, start, in_cast)
    }

    /// a type without suffixes: a tuple or parenthesized type, a fn type, a path, a comptime call
    fn type_atom(&mut self) -> Res<Type> {
        let start = self.span();
        let t = if self.eat("(") {
            let mut elems = Vec::new();
            let mut trailing_comma = false;
            while !self.eat(")") {
                let name = if self.is_ident() && self.is_at(1, ":") {
                    let n = self.ident()?.0;
                    self.bump();
                    Some(n)
                } else {
                    None
                };
                elems.push((name, self.parse_type()?));
                trailing_comma = self.eat(",");
                if !trailing_comma && !self.is(")") {
                    return self.unexpected("',' or ')'");
                }
            }
            // (T) groups; a 1-tuple is (T,)
            if elems.len() == 1 && elems[0].0.is_none() && !trailing_comma {
                return Ok(elems.pop().unwrap().1);
            }
            TypeKind::Tuple(elems)
        } else if self.is_kw("fn") || (self.is_kw("extern") && self.is_kw_at(2, "fn")) {
            let extern_c = self.eat_kw("extern");
            if extern_c {
                self.bump(); // "C"
            }
            self.bump();
            self.expect("(")?;
            let mut params = Vec::new();
            let mut c_varargs = false;
            while !self.eat(")") {
                if self.eat("...") {
                    c_varargs = true;
                    continue;
                }
                params.push(self.parse_type()?);
                if !self.eat(",") && !self.is(")") {
                    return self.unexpected("',' or ')'");
                }
            }
            let ret = if self.eat("->") {
                self.parse_type()?
            } else {
                Type { kind: TypeKind::Path(Path::single("void", self.prev_span())), span: self.prev_span() }
            };
            TypeKind::Fn { params, c_varargs, ret: Box::new(ret), extern_c }
        } else if matches!(self.tok(), Tok::Ident(s) if s == "error" || !KEYWORDS.contains(&s.as_str())) {
            let p = self.path(true)?;
            if self.is("(") {
                // a comptime function returning a type
                let pspan = p.span;
                let args = self.call_args()?;
                let callee = Expr { kind: ExprKind::Path(p), span: pspan };
                TypeKind::Expr(Box::new(Expr { kind: ExprKind::Call(Box::new(callee), args), span: start.to(self.prev_span()) }))
            } else {
                TypeKind::Path(p)
            }
        } else {
            return self.unexpected("a type");
        };
        Ok(Type { kind: t, span: start.to(self.prev_span()) })
    }

    /// the suffixes after a type: T* T& T? T... T[N] T[] T[..]
    fn type_suffixes(&mut self, first: Type, start: Span, in_cast: bool) -> Res<Type> {
        let mut t = first.kind;
        loop {
            let span = start.to(self.prev_span());
            let inner = Box::new(Type { kind: t, span });
            let suffix = |p: &Self, s: &str| p.is(s) && !(in_cast && p.starts_operand_at(1, false));
            t = if suffix(self, "*") {
                self.bump();
                TypeKind::Ptr(inner)
            } else if suffix(self, "&") {
                self.bump();
                TypeKind::Ref(inner)
            } else if self.eat("?") {
                TypeKind::Optional(inner)
            } else if self.eat("??") {
                // T?? lexes as the ?? operator: an optional of an optional
                let once = Box::new(Type { kind: TypeKind::Optional(inner), span });
                TypeKind::Optional(once)
            } else if self.eat("...") {
                TypeKind::Pack(inner)
            } else if self.is("[") && !(self.is_kw_at(1, "var") || self.is_kw_at(1, "val")) {
                // `[var`/`[val` opens a for loop's accumulator, not an array suffix
                self.bump();
                if self.eat("..") {
                    self.expect("]")?;
                    TypeKind::Slice(inner)
                } else if self.eat("]") {
                    TypeKind::Array(inner, None)
                } else {
                    let n = self.expr()?;
                    self.expect("]")?;
                    TypeKind::Array(inner, Some(Box::new(n)))
                }
            } else {
                return Ok(*inner);
            };
        }
    }

    /// a::b<T>::c. In types every `<` opens generic args; in expressions only after a generic name,
    /// or after a qualified name (ns::f<T>) when a call or `::` follows the `>` (a template from a
    /// C++ import is a generic name only the checker knows)
    fn path(&mut self, in_type: bool) -> Res<Path> {
        let start = self.span();
        let mut segs = Vec::new();
        loop {
            let name = match self.tok() {
                Tok::Ident(s) if s == "error" || !KEYWORDS.contains(&s.as_str()) => s.clone(),
                _ => return self.unexpected("a name"),
            };
            self.bump();
            let args = if self.is("<") && in_type {
                Some(self.generic_args()?)
            } else if self.is("<") && self.generics.contains(&name) {
                self.try_generic_args()
            } else if self.is("<") && !segs.is_empty() {
                let save = self.pos;
                match self.try_generic_args() {
                    Some(a) if self.is("(") || self.is("::") => Some(a),
                    _ => {
                        self.pos = save;
                        None
                    }
                }
            } else {
                None
            };
            segs.push(PathSeg { name, args });
            if self.is("::") && self.is_ident_at(1) {
                self.bump();
            } else {
                break;
            }
        }
        Ok(Path { segs, span: start.to(self.prev_span()) })
    }

    // ---------- statements ----------

    pub fn block(&mut self) -> Res<Block> {
        let start = self.expect("{")?;
        let mut stmts = Vec::new();
        loop {
            if self.is("}") {
                if self.line_col(self.pos).is_some_and(|c| c != self.indent(start.lo)) {
                    self.suspect = Some((start, self.span()));
                }
                self.bump();
                break;
            }
            if self.at_eof() || self.runs_into_item() {
                return Err(self.never_closed(start));
            }
            if self.eat(";") {
                continue;
            }
            stmts.push(self.stmt()?);
        }
        Ok(Block { stmts, span: start.to(self.prev_span()) })
    }

    /// a block runs into the next item: a line at or left of the item's column that starts with a
    /// word only items start with
    fn runs_into_item(&self) -> bool {
        const ITEM_ONLY: &[&str] = &["fn", "struct", "enum", "trait", "attach", "namespace", "internal", "public", "export", "extern"];
        self.line_col(self.pos).is_some_and(|c| c <= self.item_col) && ITEM_ONLY.iter().any(|k| self.is_kw(k))
    }

    /// a block opened at `open` reaches the next item or the end of the file. The brace most likely
    /// unclosed is one whose '}' didn't line up with it (that '}' closed it instead), else this one
    fn never_closed(&mut self, open: Span) -> Diag {
        let end = if self.at_eof() { "the file ends here" } else { "the next item starts here" };
        let here = self.span();
        match self.suspect.take() {
            Some((o, c)) => Diag::new(o, "this '{' is never closed")
                .label(c, "this '}' doesn't line up with it, but closes it")
                .label(here, end),
            None => Diag::new(open, "this '{' is never closed").label(here, end),
        }
    }

    /// the indentation of the line holding byte lo
    fn indent(&self, lo: u32) -> usize {
        let line = self.src[..lo as usize].rfind('\n').map_or(0, |n| n + 1);
        self.src.as_bytes()[line..].iter().take_while(|&&b| b == b' ' || b == b'\t').count()
    }

    /// `[static] var|val name|(a, b) [: T] [= init];`
    fn let_stmt(&mut self, comptime: bool) -> Res<Let> {
        let start = self.span();
        let is_static = self.eat_kw("static");
        let mutable = if self.eat_kw("var") {
            true
        } else {
            self.expect_kw("val")?;
            false
        };
        let pat = if self.is("(") {
            let s = self.span();
            self.bump();
            let mut elems = Vec::new();
            while !self.eat(")") {
                let (n, sp) = self.ident()?;
                elems.push(Pat { kind: PatKind::Bind(n), span: sp });
                if !self.eat(",") && !self.is(")") {
                    return self.unexpected("',' or ')'");
                }
            }
            Pat { kind: PatKind::Tuple(elems), span: s.to(self.prev_span()) }
        } else {
            let (n, sp) = self.ident()?;
            Pat { kind: PatKind::Bind(n), span: sp }
        };
        let ty = if self.eat(":") { Some(self.parse_type()?) } else { None };
        let init = if self.eat("=") { Some(self.expr()?) } else { None };
        self.expect(";")?;
        Ok(Let { mutable, comptime, is_static, pat, ty, init, span: start.to(self.prev_span()), c_name: None })
    }

    /// one statement; an expression statement needs `;` unless it ends in a block
    fn stmt(&mut self) -> Res<Stmt> {
        let start = self.span();
        let kind = if self.is_kw("var") || self.is_kw("val") || (self.is_kw("static") && !self.is_kw_at(1, "this")) {
            StmtKind::Let(self.let_stmt(false)?)
        } else if self.is_kw("comptime") && (self.is_kw_at(1, "var") || self.is_kw_at(1, "val")) {
            self.bump();
            StmtKind::Let(self.let_stmt(true)?)
        } else if self.is_kw("defer") || self.is_kw("errdefer") {
            let is_err = self.is_kw("errdefer");
            self.bump();
            let e = if self.is("{") {
                let b = self.block()?;
                Expr { span: b.span, kind: ExprKind::Block(None, b) }
            } else {
                let e = self.expr()?;
                self.expect(";")?;
                e
            };
            if is_err { StmtKind::ErrDefer(e) } else { StmtKind::Defer(e) }
        } else if self.eat_kw("suspend") {
            self.expect(";")?;
            StmtKind::Suspend
        } else if self.eat_kw("resume") {
            let e = self.expr()?;
            self.expect(";")?;
            StmtKind::Resume(e)
        } else if self.is("{") {
            let b = self.block()?;
            StmtKind::Expr(Expr { span: b.span, kind: ExprKind::Block(None, b) })
        } else if self.starts_block_stmt() {
            // a statement that starts with if/match/for/while/loop ends at its '}':
            // `if (c) { .. } *p = 1;` is two statements, not a multiplication
            let e = self.primary()?;
            self.eat(";");
            StmtKind::Expr(e)
        } else {
            let e = self.expr()?;
            let block_like = matches!(
                e.kind,
                ExprKind::If { .. } | ExprKind::While(..) | ExprKind::Loop(..) | ExprKind::For(_) | ExprKind::Match { .. } | ExprKind::Block(..)
            );
            if !self.eat(";") && !block_like {
                return self.unexpected("';'");
            }
            StmtKind::Expr(e)
        };
        Ok(Stmt { kind, span: start.to(self.prev_span()) })
    }

    /// if/match/for/while/loop, maybe after `comptime` or a `:label`
    fn starts_block_stmt(&self) -> bool {
        let kw = |k: &str| matches!(k, "if" | "match" | "for" | "while" | "loop");
        match self.tok() {
            Tok::Ident(s) if kw(s) => true,
            Tok::Ident(s) if s == "comptime" => matches!(self.tok_at(1), Tok::Ident(k) if kw(k)),
            Tok::Punct(":") => self.is_ident_at(1) && matches!(self.tok_at(2), Tok::Ident(k) if kw(k)),
            _ => false,
        }
    }

    // ---------- expressions ----------

    /// a full expression: an assignment (right-assoc, lowest precedence) or an operator expression
    pub fn expr(&mut self) -> Res<Expr> {
        let lhs = self.bin(0)?;
        let op = if self.is("=") {
            Some(None)
        } else if self.is(">") && self.glued_at(1) && self.is_at(1, ">=") {
            // `>>=` lexes as `>` then a glued `>=`
            self.bump();
            Some(Some(BinOp::Shr))
        } else {
            let op = match self.tok() {
                Tok::Punct(p) => match *p {
                    "+=" => Some(BinOp::Add),
                    "-=" => Some(BinOp::Sub),
                    "*=" => Some(BinOp::Mul),
                    "/=" => Some(BinOp::Div),
                    "%=" => Some(BinOp::Rem),
                    "&=" => Some(BinOp::BitAnd),
                    "|=" => Some(BinOp::BitOr),
                    "^=" => Some(BinOp::BitXor),
                    "<<=" => Some(BinOp::Shl),
                    "+%=" => Some(BinOp::WAdd),
                    "-%=" => Some(BinOp::WSub),
                    "*%=" => Some(BinOp::WMul),
                    _ => None,
                },
                _ => None,
            };
            op.map(Some)
        };
        if let Some(op) = op {
            self.bump();
            let rhs = self.expr()?;
            let span = lhs.span.to(rhs.span);
            return Ok(Expr { kind: ExprKind::Assign(op, Box::new(lhs), Box::new(rhs)), span });
        }
        Ok(lhs)
    }

    /// the current token as an infix operator and its precedence (higher binds tighter); `>>` is two
    /// glued `>` tokens
    fn infix(&self) -> Option<(u8, Infix)> {
        use BinOp::*;
        let b = |p: u8, op: BinOp| Some((p, Infix::Bin(op, 1)));
        match self.tok() {
            Tok::Ident(s) if s == "catch" => Some((PREC_ORELSE, Infix::Catch)),
            Tok::Ident(s) if s == "as" => Some((12, Infix::As)),
            Tok::Punct(p) => match *p {
                "??" => Some((PREC_ORELSE, Infix::OrElse)),
                ".." => Some((PREC_RANGE, Infix::Range(false))),
                "..=" => Some((PREC_RANGE, Infix::Range(true))),
                "||" => b(3, Or),
                "&&" => b(4, And),
                "==" => b(5, Eq),
                "!=" => b(5, Ne),
                "<" => b(5, Lt),
                "<=" => b(5, Le),
                ">=" => b(5, Ge),
                ">" => {
                    if self.glued_at(1) && self.is_at(1, ">") {
                        Some((9, Infix::Bin(Shr, 2)))
                    } else if self.glued_at(1) && self.is_at(1, ">=") {
                        None // >>= assignment
                    } else {
                        b(5, Gt)
                    }
                }
                "|" => b(6, BitOr),
                "^" => b(7, BitXor),
                "&" => b(8, BitAnd),
                "<<" => b(9, Shl),
                "+" => b(10, Add),
                "-" => b(10, Sub),
                "+%" => b(10, WAdd),
                "-%" => b(10, WSub),
                "*" => b(11, Mul),
                "/" => b(11, Div),
                "%" => b(11, Rem),
                "*%" => b(11, WMul),
                _ => None,
            },
            _ => None,
        }
    }

    /// can the current token start an operand (for open ranges and break/return values)?
    /// `{` only counts when allowed: `0..100 {` is a range then a loop body, `return { a }` is a literal
    fn starts_operand(&self, brace: bool) -> bool {
        self.starts_operand_at(0, brace)
    }

    fn starts_operand_at(&self, n: usize, brace: bool) -> bool {
        match self.tok_at(n) {
            Tok::Eof => false,
            Tok::Punct("{") => brace,
            Tok::Punct(p) => !matches!(*p, "]" | ")" | "}" | "," | ";" | "=>" | "=" | ":"),
            Tok::Ident(s) => !matches!(s.as_str(), "else" | "catch" | "as" | "in"),
            _ => true,
        }
    }

    /// precedence climbing over operators binding at least `min`. Binary ops are left-assoc; `??` and
    /// `catch` are right-assoc, and a range's end is optional (`a..`)
    fn bin(&mut self, min: u8) -> Res<Expr> {
        let mut lhs = self.unary()?;
        while let Some((prec, op)) = self.infix() {
            if prec < min {
                break;
            }
            let start = lhs.span;
            let kind = match op {
                Infix::Bin(op, n) => {
                    for _ in 0..n {
                        self.bump();
                    }
                    let rhs = self.bin(prec + 1)?;
                    ExprKind::Binary(op, Box::new(lhs), Box::new(rhs))
                }
                Infix::OrElse => {
                    self.bump();
                    let rhs = self.bin(prec)?;
                    ExprKind::OrElse(Box::new(lhs), Box::new(rhs))
                }
                Infix::Catch => {
                    self.bump();
                    let cap = if self.eat("|") {
                        let c = self.ident()?;
                        self.expect("|")?;
                        Some(c)
                    } else {
                        None
                    };
                    let handler = if self.is("{") {
                        let b = self.block()?;
                        Expr { span: b.span, kind: ExprKind::Block(None, b) }
                    } else {
                        self.bin(prec)?
                    };
                    ExprKind::Catch(Box::new(lhs), cap, Box::new(handler))
                }
                Infix::Range(incl) => {
                    self.bump();
                    let rhs = if self.starts_operand(false) { Some(Box::new(self.bin(prec + 1)?)) } else { None };
                    ExprKind::Range(Some(Box::new(lhs)), rhs, incl)
                }
                Infix::As => {
                    self.bump();
                    let t = self.type_core(true)?;
                    ExprKind::Cast(Box::new(lhs), t)
                }
            };
            lhs = Expr { kind, span: start.to(self.prev_span()) };
        }
        Ok(lhs)
    }

    /// prefix operators and try/await/async/move/copy, then a postfix expression
    fn unary(&mut self) -> Res<Expr> {
        let start = self.span();
        let op = match self.tok() {
            Tok::Punct("-") => Some(UnOp::Neg),
            Tok::Punct("!") => Some(UnOp::Not),
            Tok::Punct("~") => Some(UnOp::BitNot),
            Tok::Punct("&") => Some(UnOp::Addr),
            Tok::Punct("*") => Some(UnOp::Deref),
            _ => None,
        };
        let wrap = |k: fn(P<Expr>) -> ExprKind, e: Expr| Expr { span: start.to(e.span), kind: k(Box::new(e)) };
        if let Some(op) = op {
            self.bump();
            let e = self.unary()?;
            return Ok(Expr { span: start.to(e.span), kind: ExprKind::Unary(op, Box::new(e)) });
        }
        if let Tok::Ident(s) = self.tok() {
            let k: Option<fn(P<Expr>) -> ExprKind> = match s.as_str() {
                "try" => Some(ExprKind::Try),
                "await" => Some(ExprKind::Await),
                "async" => Some(ExprKind::Async),
                "move" => Some(ExprKind::Move),
                "copy" => Some(ExprKind::Copy),
                _ => None,
            };
            if let Some(k) = k {
                self.bump();
                let e = self.unary()?;
                return Ok(wrap(k, e));
            }
        }
        self.postfix()
    }

    /// calls, indexing, fields (a.b, a.0, a.f<T>, p->b) and `++`/`--` after a primary
    fn postfix(&mut self) -> Res<Expr> {
        let mut e = self.primary()?;
        loop {
            let start = e.span;
            let kind = if self.is("(") {
                let args = self.call_args()?;
                ExprKind::Call(Box::new(e), args)
            } else if self.is("[") && !(self.is_kw_at(1, "var") || self.is_kw_at(1, "val")) {
                // `[var`/`[val` opens a for loop's accumulator, not an index
                self.bump();
                let idx = self.expr()?;
                self.expect("]")?;
                ExprKind::Index(Box::new(e), Box::new(idx))
            } else if self.is(".") && matches!(self.tok_at(1), Tok::Ident(_) | Tok::Int(_)) {
                self.bump();
                let t = self.bump();
                let name = match t.tok {
                    Tok::Ident(s) => s,
                    Tok::Int(n) => {
                        // written exactly as its decimal value: t.01 and t.0x1 are errors
                        let s = n.to_string();
                        if (t.span.hi - t.span.lo) as usize != s.len() {
                            return err(t.span, "a tuple index is a plain decimal number, like t.1");
                        }
                        s
                    }
                    _ => unreachable!(),
                };
                let args = self.method_generic_args(&name);
                ExprKind::Field(Box::new(e), name, args)
            } else if self.is("->") && self.is_ident_at(1) {
                // p->name is (*p).name
                self.bump();
                let name = self.ident()?.0;
                let args = self.method_generic_args(&name);
                let deref = Expr { kind: ExprKind::Unary(UnOp::Deref, Box::new(e)), span: start };
                ExprKind::Field(Box::new(deref), name, args)
            } else if self.is("++") || self.is("--") {
                let inc = self.bump().tok == Tok::Punct("++");
                ExprKind::IncDec(Box::new(e), inc)
            } else {
                return Ok(e);
            };
            e = Expr { kind, span: start.to(self.prev_span()) };
        }
    }

    fn call_args(&mut self) -> Res<Vec<Expr>> {
        self.expect("(")?;
        let mut args = Vec::new();
        while !self.eat(")") {
            args.push(self.expr()?);
            if !self.eat(",") && !self.is(")") {
                return self.unexpected("',' or ')'");
            }
        }
        Ok(args)
    }

    /// `@name<T>(args)`: only GENERIC_BUILTINS take `<...>`, each arg may be a type or a value, and the
    /// parentheses are optional
    fn builtin(&mut self) -> Res<Expr> {
        let start = self.span();
        let name = match self.bump().tok {
            Tok::Builtin(s) => s,
            _ => unreachable!(),
        };
        let generics = if self.is("<") && GENERIC_BUILTINS.contains(&name.as_str()) { self.generic_args()? } else { Vec::new() };
        let args = if self.eat("(") {
            let mut args = Vec::new();
            while !self.eat(")") {
                args.push(self.generic_arg(")")?);
                if !self.eat(",") && !self.is(")") {
                    return self.unexpected("',' or ')'");
                }
            }
            Some(args)
        } else {
            None
        };
        Ok(Expr { kind: ExprKind::Builtin(name, generics, args), span: start.to(self.prev_span()) })
    }

    /// an optional `:name` loop or block label
    fn label(&mut self) -> Res<Option<String>> {
        if self.is(":") && self.is_ident_at(1) {
            self.bump();
            Ok(Some(self.ident()?.0))
        } else {
            Ok(None)
        }
    }

    /// a literal, name, `(...)`, `{...}` literal, closure, label, `.VARIANT`, open range, or a keyword
    /// expression (return, break, if, match, loops...)
    fn primary(&mut self) -> Res<Expr> {
        let start = self.span();
        let mk = |kind, p: &Self| Ok(Expr { kind, span: start.to(p.prev_span()) });
        match self.tok().clone() {
            Tok::Int(v) => {
                self.bump();
                mk(ExprKind::Int(v), self)
            }
            Tok::Float(v) => {
                self.bump();
                mk(ExprKind::Float(v), self)
            }
            Tok::Char(v) => {
                self.bump();
                mk(ExprKind::Char(v), self)
            }
            Tok::Str(s) => {
                self.bump();
                mk(ExprKind::Str(s), self)
            }
            Tok::Builtin(_) => self.builtin(),
            // `()` is the empty tuple, `(e)` groups, and a comma makes a tuple: `(e,)`
            Tok::Punct("(") => {
                self.bump();
                if self.eat(")") {
                    return mk(ExprKind::Tuple(Vec::new()), self);
                }
                let first = self.expr()?;
                if self.eat(")") {
                    return Ok(first);
                }
                let mut elems = vec![first];
                while self.eat(",") {
                    if self.is(")") {
                        break;
                    }
                    elems.push(self.expr()?);
                }
                self.expect(")")?;
                mk(ExprKind::Tuple(elems), self)
            }
            Tok::Punct("{") => {
                self.bump();
                let mut entries = Vec::new();
                while !self.eat("}") {
                    let name = if self.is_ident() && self.is_at(1, ":") {
                        let n = self.ident()?.0;
                        self.bump();
                        Some(n)
                    } else {
                        None
                    };
                    entries.push((name, self.expr()?));
                    // { x; n }: n copies of x
                    if entries.len() == 1 && entries[0].0.is_none() && self.eat(";") {
                        let n = self.expr()?;
                        self.expect("}")?;
                        let x = entries.pop().unwrap().1;
                        return mk(ExprKind::Repeat(Box::new(x), Box::new(n)), self);
                    }
                    if !self.eat(",") && !self.is("}") {
                        return self.unexpected("',' or '}'");
                    }
                }
                mk(ExprKind::Literal(entries), self)
            }
            Tok::Punct("|") | Tok::Punct("||") => self.closure(),
            Tok::Punct(":") if self.is_ident_at(1) => {
                let label = self.label()?;
                if self.is("{") {
                    let b = self.block()?;
                    return mk(ExprKind::Block(label, b), self);
                }
                if !(self.is_kw("for") || self.is_kw("while") || self.is_kw("loop")) {
                    return self.unexpected("for, while or loop after a label");
                }
                self.loop_expr(label, false)
            }
            Tok::Punct(".") if self.is_ident_at(1) => {
                self.bump();
                let (n, _) = self.ident()?;
                mk(ExprKind::DotVariant(n), self)
            }
            Tok::Punct(p @ (".." | "..=")) => {
                self.bump();
                let rhs = if self.starts_operand(false) { Some(Box::new(self.bin(PREC_RANGE + 1)?)) } else { None };
                mk(ExprKind::Range(None, rhs, p == "..="), self)
            }
            Tok::Ident(s) => match s.as_str() {
                "true" | "false" => {
                    self.bump();
                    mk(ExprKind::Bool(s == "true"), self)
                }
                "null" => {
                    self.bump();
                    mk(ExprKind::Null, self)
                }
                "this" => {
                    self.bump();
                    mk(ExprKind::This, self)
                }
                "error" if !self.is_at(1, "::") => {
                    self.bump();
                    mk(ExprKind::ErrorAny, self)
                }
                "return" => {
                    self.bump();
                    let v = if self.starts_operand(true) { Some(Box::new(self.expr()?)) } else { None };
                    mk(ExprKind::Return(v), self)
                }
                "break" => {
                    self.bump();
                    let label = self.label()?;
                    let v = if self.starts_operand(true) { Some(Box::new(self.expr()?)) } else { None };
                    mk(ExprKind::Break(label, v), self)
                }
                "continue" => {
                    self.bump();
                    let label = self.label()?;
                    mk(ExprKind::Continue(label), self)
                }
                "comptime" => {
                    self.bump();
                    if !(self.is_kw("if") || self.is_kw("match") || self.is_kw("for")) {
                        return self.unexpected("if, match or for after comptime");
                    }
                    self.loop_expr(None, true)
                }
                "if" | "match" | "for" | "while" | "loop" => self.loop_expr(None, false),
                _ if !KEYWORDS.contains(&s.as_str()) || s == "error" => {
                    let p = self.path(false)?;
                    mk(ExprKind::Path(p), self)
                }
                _ => self.unexpected("an expression"),
            },
            _ => self.unexpected("an expression"),
        }
    }

    /// if / match / for / while / loop, with an optional label and comptime flag
    fn loop_expr(&mut self, label: Option<String>, comptime: bool) -> Res<Expr> {
        let start = self.span();
        let kind = if self.eat_kw("if") {
            self.expect("(")?;
            let cond = self.expr()?;
            self.expect(")")?;
            let then = self.block()?;
            let els = if self.eat_kw("else") {
                if self.is_kw("if") {
                    Some(Box::new(self.loop_expr(None, comptime)?))
                } else if self.is_kw("comptime") && self.is_kw_at(1, "if") {
                    // `else comptime if`: that branch is decided in the compiler (after `comptime if`, so is a plain `else if`)
                    self.bump();
                    Some(Box::new(self.loop_expr(None, true)?))
                } else {
                    let b = self.block()?;
                    Some(Box::new(Expr { span: b.span, kind: ExprKind::Block(None, b) }))
                }
            } else {
                None
            };
            ExprKind::If { cond: Box::new(cond), then, els, comptime }
        } else if self.eat_kw("match") {
            self.expect("(")?;
            let scrut = self.expr()?;
            self.expect(")")?;
            self.expect("{")?;
            let mut arms = Vec::new();
            while !self.eat("}") {
                let astart = self.span();
                let pat = self.pat()?;
                let guard = if self.eat_kw("if") { Some(self.expr()?) } else { None };
                self.expect("=>")?;
                let body = if self.is("{") {
                    let b = self.block()?;
                    Expr { span: b.span, kind: ExprKind::Block(None, b) }
                } else {
                    self.expr()?
                };
                arms.push(Arm { pat, guard, body, span: astart.to(self.prev_span()) });
                if !self.eat(",") && !self.eat(";") && !self.is("}") {
                    return self.unexpected("',' or '}' after match arm");
                }
            }
            ExprKind::Match { scrut: Box::new(scrut), arms, comptime }
        } else if self.eat_kw("while") {
            self.expect("(")?;
            let cond = self.expr()?;
            self.expect(")")?;
            ExprKind::While(label, Box::new(cond), self.block()?)
        } else if self.eat_kw("loop") {
            ExprKind::Loop(label, self.block()?)
        } else if self.eat_kw("for") {
            self.expect("(")?;
            let mut bindings = Vec::new();
            while !self.eat(")") {
                let (n, sp) = self.ident()?;
                let by_ref = self.eat("&");
                bindings.push((n, by_ref, sp));
                if !self.eat(",") && !self.is(")") {
                    return self.unexpected("',' or ')'");
                }
            }
            self.expect_kw("in")?;
            let iter = self.expr()?;
            let map = if self.eat("=>") { Some(self.expr()?) } else { None };
            let acc = if self.is("[") {
                self.bump();
                let astart = self.span();
                let mutable = if self.eat_kw("var") {
                    true
                } else {
                    self.expect_kw("val")?;
                    false
                };
                let (n, sp) = self.ident()?;
                let ty = if self.eat(":") { Some(self.parse_type()?) } else { None };
                let init = if self.eat("=") { Some(self.expr()?) } else { None };
                self.expect("]")?;
                Some(Let {
                    mutable,
                    comptime: false,
                    is_static: false,
                    pat: Pat { kind: PatKind::Bind(n), span: sp },
                    ty,
                    init,
                    span: astart.to(self.prev_span()),
                    c_name: None,
                })
            } else {
                None
            };
            let body = self.block()?;
            ExprKind::For(Box::new(ForLoop { label, bindings, iter, map, acc, body, comptime }))
        } else {
            return self.unexpected("for, while or loop after a label");
        };
        Ok(Expr { kind, span: start.to(self.prev_span()) })
    }

    /// `|a, b&, move c| (params) -> R { body }`: captures copy unless marked `&` (by reference) or `move`;
    /// `|c| <T: type>(x: T) { }` is generic
    fn closure(&mut self) -> Res<Expr> {
        let start = self.span();
        let mut caps = Vec::new();
        if !self.eat("||") {
            self.expect("|")?;
            while !self.eat("|") {
                let cs = self.span();
                let mode_move = self.eat_kw("move");
                let (name, _) = self.ident()?;
                let mode = if mode_move {
                    CapMode::Move
                } else if self.eat("&") {
                    CapMode::Ref
                } else {
                    CapMode::Copy
                };
                caps.push(Capture { name, mode, span: cs.to(self.prev_span()) });
                if !self.eat(",") && !self.is("|") {
                    return self.unexpected("',' or '|'");
                }
            }
        }
        let generics = if self.is("<") { self.generic_params()? } else { Vec::new() };
        let (params, _) = self.params()?;
        let ret = if self.eat("->") { Some(self.parse_type()?) } else { None };
        let body = self.block()?;
        Ok(Expr { kind: ExprKind::Closure { caps, generics, params, ret, body }, span: start.to(self.prev_span()) })
    }

    /// a match pattern. A bare name binds (`n`, or `n&` by reference); a constructor needs `.X`, a
    /// qualified path or parentheses
    fn pat(&mut self) -> Res<Pat> {
        let start = self.span();
        let mk = |kind, p: &Self| Ok(Pat { kind, span: start.to(p.prev_span()) });
        if self.eat_kw("default") || matches!(self.tok(), Tok::Ident(s) if s == "_") {
            if self.is_kw("_") {
                self.bump();
            }
            return mk(PatKind::Wild, self);
        }
        if self.is(".") && self.is_ident_at(1) {
            self.bump();
            let (n, _) = self.ident()?;
            let args = self.pat_args()?;
            return mk(PatKind::Ctor(CtorPath::Dot(n), args), self);
        }
        if self.eat("(") {
            let mut elems = Vec::new();
            while !self.eat(")") {
                elems.push(self.pat()?);
                if !self.eat(",") && !self.is(")") {
                    return self.unexpected("',' or ')'");
                }
            }
            return mk(PatKind::Tuple(elems), self);
        }
        let is_lit = matches!(self.tok(), Tok::Int(_) | Tok::Float(_) | Tok::Char(_) | Tok::Str(_))
            || (self.is("-") && matches!(self.tok_at(1), Tok::Int(_) | Tok::Float(_)))
            || self.is_kw("true")
            || self.is_kw("false")
            || self.is_kw("null");
        if is_lit {
            let lo = self.unary()?;
            if self.is("..") || self.is("..=") {
                let incl = self.bump().tok == Tok::Punct("..=");
                let hi = self.unary()?;
                return mk(PatKind::Range(lo, hi, incl), self);
            }
            return mk(PatKind::Lit(lo), self);
        }
        let p = self.path(false)?;
        if self.is("(") {
            let args = self.pat_args()?;
            return mk(PatKind::Ctor(CtorPath::Path(p), args), self);
        }
        if p.is_single() {
            if self.eat("&") {
                return mk(PatKind::BindRef(p.segs[0].name.clone()), self);
            }
            return mk(PatKind::Bind(p.segs[0].name.clone()), self);
        }
        mk(PatKind::Ctor(CtorPath::Path(p), None), self)
    }

    fn pat_args(&mut self) -> Res<Option<Vec<Pat>>> {
        if !self.eat("(") {
            return Ok(None);
        }
        let mut args = Vec::new();
        while !self.eat(")") {
            args.push(self.pat()?);
            if !self.eat(",") && !self.is(")") {
                return self.unexpected("',' or ')'");
            }
        }
        Ok(Some(args))
    }
}

/// Lex + parse several files with one shared generic-name set; every file's errors (a lexer error
/// stops its file, a parse error its item)
pub fn parse_files(files: &[(u32, &str)]) -> Result<Vec<Vec<Item>>, Vec<Diag>> {
    let mut toks = Vec::new();
    let mut errors = Vec::new();
    for (id, src) in files {
        match crate::lexer::lex(src, *id) {
            Ok(t) => toks.push((t, *src)),
            Err(d) => errors.push(d),
        }
    }
    let mut names = HashSet::new();
    for (t, _) in &toks {
        collect_generic_names(t, &mut names);
    }
    let mut parsed = Vec::new();
    for (t, src) in &toks {
        match Parser::new(t, &names, src).parse_file() {
            Ok(items) => parsed.push(items),
            Err(ds) => errors.extend(ds),
        }
    }
    if errors.is_empty() {
        Ok(parsed)
    } else {
        errors.sort_by_key(|d| (d.span.file, d.span.lo));
        Err(errors)
    }
}
