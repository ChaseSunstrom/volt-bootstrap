// Recursive descent + precedence climbing: a port of bootstrap/parser.rs, kept
// in step with it (same trees, spans and messages). `f<T>(...)` in an expression is a generic call
// only when f names a generic (found by a token scan of every file first).
use std::mem;

// words that are never a name (`ident` rejects them); `error` still starts a path (`error::X`)
val KEYWORDS: str[] = {
    "var", "val", "static", "public", "internal", "attach", "struct", "enum", "fn", "error", "trait", "comptime",
    "async", "await", "suspend", "resume", "extern", "export", "namespace", "use", "as", "this", "move", "copy",
    "if", "else", "for", "in", "while", "loop", "break", "continue", "return", "match", "default", "try", "catch",
    "defer", "errdefer", "true", "false", "null",
};

fn is_keyword(s: str) -> bool {
    for (k) in KEYWORDS {
        if (k == s) {
            return true;
        }
    }
    return false;
}

// append, or stop: running out of memory in the compiler isn't recoverable
<T: type>
fn put(v: std::vec<T>&, x: T) -> void {
    v.push(move x) catch @panic("out of memory");
}

// move every element of src to the end of dst
<T: type>
fn extend(dst: std::vec<T>&, var src: std::vec<T>) -> void {
    for (i) in 0..src.len {
        put(dst, @read(src.at(i)));
    }
    src.len = 0; // moved out: only the buffer is left to free
}

fn ident_of(t: tok&) -> str? {
    match (*t) {
        .IDENT(s) => { return s; },
        default => { return null; },
    }
}

fn punct_of(t: tok&) -> str? {
    match (*t) {
        .PUNCT(p) => { return p; },
        default => { return null; },
    }
}

// appends v in decimal
fn append_u128(s: std::string&, v: u128) -> void {
    var digits: u8[40];
    var n: usize = 0;
    var x = v;
    loop {
        digits[n] = @cast<u8>(x % 10) + '0';
        n += 1;
        x = x / 10;
        if (x == 0) {
            break;
        }
    }
    while (n > 0) {
        n -= 1;
        s.push(digits[n]);
    }
}

// Names declared with a generic prefix: `<...> [modifiers] fn|struct|enum|trait|error|type NAME`.
// whether the token is @attributes
fn is_attributes(t: tok&) -> bool {
    match (*t) {
        .BUILTIN(s) => { return s == "attributes"; },
        default => { return false; },
    }
}

fn collect_generic_names(toks: std::vec<token>&, out: std::map<str, bool>&) -> void {
    for (i) in 0..toks.len {
        if ((punct_of(&(toks.at(i).tok)) ?? "") != ">") {
            continue;
        }
        var j = i + 1;
        loop {
            if (j >= toks.len) {
                break;
            }
            val w = ident_of(&(toks.at(j).tok)) ?? "";
            if (w == "public" || w == "internal" || w == "comptime" || w == "async" || w == "export" || w == "attach" || w == "static") {
                j += 1;
            } else if (w == "extern") {
                j += 1;
                if (j < toks.len) {
                    match (toks.at(j).tok) {
                        .STR(s) => { j += 1; },
                        default => {},
                    }
                }
            } else if (is_attributes(&(toks.at(j).tok))) {
                // @attributes([...]) between the generics and the declaration: past its parens
                j += 1;
                var depth = 0;
                while (j < toks.len) {
                    val p = punct_of(&(toks.at(j).tok)) ?? "";
                    j += 1;
                    if (p == "(") {
                        depth += 1;
                    } else if (p == ")") {
                        depth -= 1;
                        if (depth == 0) {
                            break;
                        }
                    }
                }
            } else {
                break;
            }
        }
        if (j + 1 < toks.len) {
            val w = ident_of(&(toks.at(j).tok)) ?? "";
            if (w == "fn" || w == "struct" || w == "enum" || w == "trait" || w == "error" || w == "type") {
                match (toks.at(j + 1).tok) {
                    .IDENT(name) => { out.put(name, true); },
                    default => {},
                }
            }
        }
    }
}

// parses one file's tokens; `generics` is every generic name in the program (collect_generic_names) and
// `src` the file's text, for error messages and tuple indexes
struct parser {
    src: str;
    toks: std::vec<token>&;
    pos: usize;
    generics: std::map<str, bool>&;
    errors: std::vec<diag> = {}; // one per broken item (see items)
    item_col: usize = 0;         // the column the current item starts at
    // a block whose '}' didn't line up with the line that opened it, in the current item: the
    // likely culprit when a block turns out never closed
    suspect: bool = false;
    suspect_open: span = {};
    suspect_close: span = {};
}

// an infix operator as `infix` sees it; `bin` gives each kind its own parse
enum infix {
    BIN: (binop, usize), // op, tokens to consume
    OR_ELSE,
    CATCH,
    RANGE: bool,
    AS,
}

// precedences used outside the table in `infix` (higher binds tighter)
val PREC_ORELSE: u8 = 1;
val PREC_RANGE: u8 = 2;
// the lowest level a generic arg's expression parses at, so a `>` there closes the list
val PREC_BITOR: u8 = 6;

// ---------- token helpers ----------

attach fn tok(this: parser&) -> tok& {
    return &(this.toks.at(this.pos).tok);
}

// the token n ahead; past the end it's the final EOF
attach fn tok_at(this: parser&, n: usize) -> tok& {
    var i = this.pos + n;
    if (i > this.toks.len - 1) {
        i = this.toks.len - 1;
    }
    return &(this.toks.at(i).tok);
}

attach fn span(this: parser&) -> span {
    return this.toks.at(this.pos).span;
}

attach fn prev_span(this: parser&) -> span {
    if (this.pos == 0) {
        return this.toks.at(0).span;
    }
    return this.toks.at(this.pos - 1).span;
}

// whether the token n ahead has no whitespace before it
attach fn glued_at(this: parser&, n: usize) -> bool {
    val i = this.pos + n;
    return i < this.toks.len && this.toks.at(i).glued;
}

// step over the current token and return its span; never moves past the final EOF
attach fn bump(this: parser&) -> span {
    val s = this.span();
    if (this.pos < this.toks.len - 1) {
        this.pos += 1;
    }
    return s;
}

attach fn at_eof(this: parser&) -> bool {
    match (*this.tok()) {
        .EOF => { return true; },
        default => { return false; },
    }
}

attach fn is(this: parser&, p: str) -> bool {
    return (punct_of(this.tok()) ?? "") == p;
}

attach fn is_at(this: parser&, n: usize, p: str) -> bool {
    return (punct_of(this.tok_at(n)) ?? "") == p;
}

attach fn eat(this: parser&, p: str) -> bool {
    if (this.is(p)) {
        this.bump();
        return true;
    }
    return false;
}

attach fn expect(this: parser&, p: str) -> compile_error!span {
    if (this.is(p)) {
        return this.bump();
    }
    var what = std::string::from("'");
    what.append(p);
    what.append("'");
    return this.unexpected(what.as_str());
}

attach fn is_kw(this: parser&, k: str) -> bool {
    return (ident_of(this.tok()) ?? "") == k;
}

attach fn is_kw_at(this: parser&, n: usize, k: str) -> bool {
    return (ident_of(this.tok_at(n)) ?? "") == k;
}

attach fn eat_kw(this: parser&, k: str) -> bool {
    if (this.is_kw(k)) {
        this.bump();
        return true;
    }
    return false;
}

attach fn expect_kw(this: parser&, k: str) -> compile_error!span {
    if (this.is_kw(k)) {
        return this.bump();
    }
    var what = std::string::from("'");
    what.append(k);
    what.append("'");
    return this.unexpected(what.as_str());
}

// the `expected X, found Y` error at the current token
attach fn unexpected(this: parser&, what: str) -> compile_error {
    var msg = std::string::from("expected ");
    msg.append(what);
    msg.append(", found ");
    match (*this.tok()) {
        .IDENT(s) => {
            msg.append("'");
            msg.append(s);
            msg.append("'");
        },
        .INT(v) => {
            msg.append("number ");
            append_u128(&msg, v);
        },
        .FLOAT(v) => {
            // ponytail: shows the source text; Rust prints the parsed value (differs for 1e3, 1.50)
            msg.append("number ");
            msg.append(this.source_of(this.span()));
        },
        .CHAR(c) => { msg.append("char literal"); },
        .STR(s) => { msg.append("string"); },
        .BUILTIN(s) => {
            msg.append("'@");
            msg.append(s);
            msg.append("'");
        },
        .PUNCT(p) => {
            msg.append("'");
            msg.append(p);
            msg.append("'");
        },
        .EOF => { msg.append("end of file"); },
    }
    return compile_error::AT({ span: this.span(), msg: move msg });
}

attach fn source_of(this: parser&, s: span) -> str {
    return this.src[s.lo..s.hi];
}

// a name that isn't a keyword
attach fn ident(this: parser&) -> compile_error!(name: str, span: span) {
    match (*this.tok()) {
        .IDENT(s) => {
            if (!is_keyword(s)) {
                return { name: s, span: this.bump() };
            }
        },
        default => {},
    }
    return this.unexpected("a name");
}

attach fn is_ident(this: parser&) -> bool {
    val s = ident_of(this.tok()) ?? return false;
    return !is_keyword(s);
}

attach fn is_ident_at(this: parser&, n: usize) -> bool {
    val s = ident_of(this.tok_at(n)) ?? return false;
    return !is_keyword(s);
}

attach fn is_builtin(this: parser&, name: str) -> bool {
    match (*this.tok()) {
        .BUILTIN(s) => { return s == name; },
        default => { return false; },
    }
}

// ---------- items ----------

// the file's items; with errors, the first one (all of them are in this.errors)
attach fn parse_file(this: parser&) -> compile_error!std::vec<item> {
    var items = this.items(false);
    if (this.errors.len > 0) {
        return compile_error::AT(copy *this.errors.at(0));
    }
    return items;
}

// items up to the end of the file, or up to `}` in a block. An item with an error is recorded and
// skipped, so one run reports every broken item
attach fn items(this: parser&, in_block: bool) -> std::vec<item> {
    var items: std::vec<item> = {};
    while (!this.at_eof() && !(in_block && this.is("}"))) {
        val start = this.pos;
        this.item_col = this.line_col(start) ?? 0;
        this.suspect = false;
        val it = this.item() catch |e| {
            put(&this.errors, err_diag(&e));
            this.resync(start);
            continue;
        };
        put(&items, move it);
    }
    return items;
}

// after an error in the item starting at token `start`: skip to the next line that starts at that
// item's column with something that starts an item, or further left (the enclosing block's `}`).
// Indentation is the guide, since the error may be an unbalanced brace
attach fn resync(this: parser&, start: usize) -> void {
    val col = this.line_col(start) ?? 0;
    if (this.pos <= start) {
        this.bump();
    }
    while (!this.at_eof()) {
        val c = this.line_col(this.pos);
        if (c) {
            if (c < col || (c == col && this.starts_item())) {
                return;
            }
        }
        this.bump();
    }
}

// token i's column, when it's the first on its line
attach fn line_col(this: parser&, i: usize) -> usize? {
    val lo = @cast<usize>(this.toks.at(i).span.lo);
    var line = lo;
    while (line > 0 && this.src[line - 1] != '\n') {
        line -= 1;
    }
    for (k) in line..lo {
        if (this.src[k] != ' ' && this.src[k] != '\t') {
            return null;
        }
    }
    return lo - line;
}

attach fn starts_item(this: parser&) -> bool {
    match (*this.tok()) {
        .BUILTIN(b) => { return true; },
        default => {},
    }
    if (this.is("<")) {
        return true;
    }
    val starts: str[] = { "fn", "struct", "enum", "error", "trait", "attach", "use", "namespace", "val", "var", "static", "internal", "public", "async", "comptime", "export", "extern" };
    for (k) in starts {
        if (this.is_kw(k)) {
            return true;
        }
    }
    return false;
}

// one declaration. Order: @attributes and `<generic params>`, visibility, modifiers (async comptime
// export attach extern "abi"), then the keyword that says what it is
attach fn item(this: parser&) -> compile_error!item {
    val start = this.span();
    // @emit(code); declares what the comptime str of Volt source holds
    if (this.is_builtin("emit")) {
        this.bump();
        try this.expect("(");
        val e = try this.expr();
        try this.expect(")");
        try this.expect(";");
        return { kind: item_kind::EMIT(move e), span: start.to(this.prev_span()), attrs: {}, vis: vis::PUBLIC, generics: {} };
    }
    var attrs: std::vec<expr> = {};
    var generics: std::vec<generic_param> = {};
    loop {
        if (this.is_builtin("attributes")) {
            extend(&attrs, try this.attributes());
        } else if (this.is("<")) {
            generics = try this.generic_params();
        } else {
            break;
        }
    }
    var v = vis::PUBLIC;
    if (this.eat_kw("internal")) {
        v = vis::INTERNAL;
    } else {
        this.eat_kw("public");
    }
    var (is_async, is_comptime, is_export, is_attach, is_extern) = (false, false, false, false, false);
    var abi: str? = null;
    loop {
        if (this.eat_kw("async")) {
            is_async = true;
        } else if (this.eat_kw("comptime")) {
            is_comptime = true;
        } else if (this.eat_kw("export")) {
            is_export = true;
        } else if (this.eat_kw("attach")) {
            is_attach = true;
        } else if (this.eat_kw("extern")) {
            is_extern = true;
            match (*this.tok()) {
                .STR(s) => {
                    abi = s.as_str(); // the tokens outlive the tree
                    this.bump();
                },
                default => {},
            }
        } else {
            break;
        }
    }
    // the modifiers came before we knew what they modify: a fn takes them all, a struct only
    // extern/comptime/export, a global comptime; anything else ignores them. `kind` starts as a placeholder
    var kind: item_kind = item_kind::GLOBAL({ mutable: false, is_comptime: false, is_static: false, pat: { kind: pat_kind::WILD, span: start }, ty: null, init: null, span: start });
    if (this.eat_kw("fn")) {
        var f = try this.fn_decl();
        f.is_async = is_async;
        f.is_comptime = is_comptime;
        f.is_export = is_export;
        f.is_attach = is_attach;
        if (is_extern) {
            f.extern_abi = abi ?? "C";
        }
        kind = item_kind::FN(move f);
    } else if (is_attach) {
        // `attach Trait -> Target { fns }`: an attach block, since no `fn` followed
        val trait_ = try this.parse_type();
        try this.expect("->");
        val target = try this.parse_type();
        kind = item_kind::ATTACH(move trait_, move target, try this.item_block());
    } else if (this.eat_kw("struct")) {
        val name = (try this.ident()).name;
        var spec: std::vec<garg>? = null;
        if (this.is("<")) {
            spec = try this.generic_args();
        }
        var fields: std::vec<field> = {};
        if (!this.eat(";")) {
            try this.expect("{");
            while (!this.eat("}")) {
                val fstart = this.span();
                var fattrs: std::vec<expr> = {};
                match (*this.tok()) {
                    .BUILTIN(s) => {
                        if (s == "attributes") {
                            fattrs = try this.attributes();
                        }
                    },
                    default => {},
                }
                var fvis = vis::PUBLIC;
                if (this.eat_kw("internal")) {
                    fvis = vis::INTERNAL;
                } else {
                    this.eat_kw("public");
                }
                val fname = (try this.ident()).name;
                try this.expect(":");
                val t = try this.parse_type();
                var fallback: expr? = null;
                if (this.eat("=")) {
                    fallback = try this.expr();
                }
                if (!this.eat(";") && !this.eat(",") && !this.is("}")) {
                    return this.unexpected("';' after field");
                }
                put(&fields, { name: fname, ty: move t, fallback: move fallback, vis: fvis, span: fstart.to(this.prev_span()), attrs: move fattrs });
            }
        }
        kind = item_kind::STRUCT({ name: name, spec: move spec, fields: move fields, is_extern: is_extern, is_comptime: is_comptime, is_export: is_export });
    } else if (this.is_kw("enum") || this.is_kw("error")) {
        val is_error = this.is_kw("error");
        this.bump();
        val name = (try this.ident()).name;
        var backing: ty? = null;
        if (!is_error && this.eat(":")) {
            backing = try this.parse_type();
        }
        try this.expect("{");
        var variants: std::vec<variant> = {};
        while (!this.eat("}")) {
            val vstart = this.span();
            val vname = (try this.ident()).name;
            var payload: ty? = null;
            if (this.eat(":")) {
                payload = try this.parse_type();
            }
            var value: expr? = null;
            if (this.eat("=")) {
                value = try this.expr();
            }
            put(&variants, { name: vname, payload: move payload, value: move value, span: vstart.to(this.prev_span()) });
            if (!this.eat(",") && !this.is("}")) {
                return this.unexpected("',' or '}'");
            }
        }
        kind = item_kind::ENUM({ name: name, backing: move backing, variants: move variants, is_error: is_error });
    } else if (this.is_kw("type") && is_ident_tok(this.tok_at(1)) && is_punct_tok(this.tok_at(2), "=")) {
        // `type name = T;`: another name for a type (`<T: type> type list = std::vec<T>;`)
        this.bump();
        val name = (try this.ident()).name;
        try this.expect("=");
        val t = try this.parse_type();
        try this.expect(";");
        kind = item_kind::ALIAS(name, move t);
    } else if (this.eat_kw("trait")) {
        val name = (try this.ident()).name;
        kind = item_kind::TRAIT(name, try this.item_block());
    } else if (this.eat_kw("namespace")) {
        var path: std::vec<str> = {};
        put(&path, (try this.ident()).name);
        while (this.eat("::")) {
            put(&path, (try this.ident()).name);
        }
        kind = item_kind::NAMESPACE(move path, try this.item_block());
    } else if (this.eat_kw("use")) {
        // `use cpp { ... }`: C++ headers; `use rust { ... }` and the like: another language's code
        // (`use cpp::x;` is still a path)
        var lang: str? = null;
        match (*this.tok()) {
            .IDENT(n) => {
                match (*this.tok_at(1)) {
                    .PUNCT(p) => {
                        if (p == "{") {
                            lang = n;
                        }
                    },
                    default => {},
                }
            },
            default => {},
        }
        if (lang) {
            this.bump();
        }
        if (this.eat("{")) {
            var headers: std::vec<std::string> = {};
            while (!this.eat("}")) {
                var got = false;
                match (*this.tok()) {
                    .STR(s) => {
                        put(&headers, copy s);
                        got = true;
                    },
                    default => {},
                }
                if (!got) {
                    if (lang != null) {
                        return this.unexpected("a string");
                    }
                    return this.unexpected("a header name string");
                }
                this.bump();
                if (!this.eat(",") && !this.is("}")) {
                    return this.unexpected("',' or '}'");
                }
            }
            try this.expect_kw("as");
            val alias = (try this.ident()).name;
            try this.expect(";");
            val l = lang ?? "";
            if (lang == null) {
                kind = item_kind::USE_C(move headers, alias);
            } else if (l == "cpp") {
                kind = item_kind::USE_CPP(move headers, alias);
            } else {
                kind = item_kind::USE_LANG(l, move headers, alias);
            }
        } else {
            val p = try this.path(false);
            try this.expect(";");
            kind = item_kind::USE(move p);
        }
    } else if (this.is_kw("var") || this.is_kw("val") || this.is_kw("static")) {
        kind = item_kind::GLOBAL(try this.let_stmt(is_comptime));
    } else {
        return this.unexpected("an item (fn, struct, enum, error, trait, type, attach, namespace, use, var, val)");
    }
    return { kind: move kind, span: start.to(this.prev_span()), attrs: move attrs, vis: v, generics: move generics };
}

attach fn item_block(this: parser&) -> compile_error!std::vec<item> {
    try this.expect("{");
    var items = this.items(true);
    if (!this.eat("}")) {
        return this.unexpected("'}'");
    }
    return items;
}

// @attributes([@inline, @opt(3)])
attach fn attributes(this: parser&) -> compile_error!std::vec<expr> {
    this.bump();
    try this.expect("(");
    try this.expect("[");
    var out: std::vec<expr> = {};
    while (!this.eat("]")) {
        // a builtin (@inline), or a library's attribute: a value (json::rename("id"))
        var is_b = false;
        match (*this.tok()) {
            .BUILTIN(s) => { is_b = true; },
            default => {},
        }
        if (is_b) {
            put(&out, try this.builtin());
        } else {
            put(&out, try this.expr());
        }
        if (!this.eat(",") && !this.is("]")) {
            return this.unexpected("',' or ']'");
        }
    }
    try this.expect(")");
    return out;
}

// `<T: type, N: usize = 4, Args: type...>`; `+` joins bounds, and a `...` bound makes the param a pack
attach fn generic_params(this: parser&) -> compile_error!std::vec<generic_param> {
    try this.expect("<");
    var out: std::vec<generic_param> = {};
    while (!this.is(">")) {
        val start = this.span();
        val name = (try this.ident()).name;
        var bounds: std::vec<ty> = {};
        var pack = false;
        if (this.eat(":")) {
            loop {
                // `type...`: the bound is the type, and the param is a pack
                put(&bounds, try this.type_ext(true));
                if (this.eat("...")) {
                    pack = true;
                }
                if (!this.eat("+")) {
                    break;
                }
            }
        }
        var fallback: garg? = null;
        if (this.eat("=")) {
            fallback = try this.generic_arg(">");
        }
        put(&out, { name: name, bounds: move bounds, pack: pack, fallback: move fallback, span: start.to(this.prev_span()) });
        if (!this.eat(",") && !this.is(">")) {
            return this.unexpected("',' or '>'");
        }
    }
    try this.expect(">");
    return out;
}

// `<...>` after a name that is generic somewhere, in an expression: if it doesn't parse as
// generic args, it was a less-than (a local that shares the name: `free < cap`)
attach fn try_generic_args(this: parser&) -> std::vec<garg>? {
    val save = this.pos;
    val a = this.generic_args() catch |e| {
        this.pos = save;
        return null;
    };
    return a;
}

// `.name<...>`'s generic args: a name the program declares generic takes them; any other only when a
// call follows (`x.get<i32>()`: a method declared where the program's names aren't collected, like an
// import's), with one argument or none passed (`f(a.x < b, c > (d))` is two comparisons)
attach fn method_generic_args(this: parser&, name: str) -> std::vec<garg>? {
    if (!this.is("<")) {
        return null;
    }
    if (this.generics.get(name) != null) {
        return this.try_generic_args();
    }
    val save = this.pos;
    val a = this.try_generic_args();
    var n: usize = 0;
    if (a) {
        n = a.len;
    }
    if (a != null && this.is("(") && (n == 1 || this.is_at(1, ")"))) {
        return a;
    }
    this.pos = save;
    return null;
}

attach fn generic_args(this: parser&) -> compile_error!std::vec<garg> {
    try this.expect("<");
    var out: std::vec<garg> = {};
    while (!this.is(">")) {
        put(&out, try this.generic_arg(">"));
        if (!this.eat(",") && !this.is(">")) {
            return this.unexpected("',' or '>'");
        }
    }
    try this.expect(">");
    return out;
}

// a type, if one parses cleanly up to `,`/closer
attach fn type_garg(this: parser&, closer: str) -> garg? {
    val t = this.parse_type() catch |e| {
        return null;
    };
    if (this.is(",") || this.is(closer)) {
        return garg::TYPE(move t);
    }
    return null;
}

// an expression from pos on (after a failed type_garg)
attach fn value_garg(this: parser&, pos: usize, closer: str) -> compile_error!garg {
    this.pos = pos;
    if (closer == ">") {
        return garg::EXPR(try this.bin(PREC_BITOR));
    }
    return garg::EXPR(try this.expr());
}

// a type if one parses cleanly up to `,`/closer, else an expression
attach fn generic_arg(this: parser&, closer: str) -> compile_error!garg {
    val save = this.pos;
    val g = this.type_garg(closer) ?? return this.value_garg(save, closer);
    return g;
}

// the part after `fn`; `item` fills in the modifiers
attach fn fn_decl(this: parser&) -> compile_error!fn_decl {
    // `copy` is a keyword but also the name of the copy hook: attach fn copy(this: T&) -> T
    var name = "copy";
    if (!this.eat_kw("copy")) {
        name = (try this.ident()).name;
    }
    var spec: std::vec<garg>? = null;
    if (this.is("<")) {
        spec = try this.generic_args();
    }
    var ps: std::vec<param> = {};
    val c_varargs = try this.params(&ps);
    var ret: ty? = null;
    if (this.eat("->")) {
        ret = try this.parse_type();
    }
    var body: block? = null;
    if (!this.eat(";")) {
        body = try this.block();
    }
    return {
        name: name,
        spec: move spec,
        params: move ps,
        c_varargs: c_varargs,
        ret: move ret,
        body: move body,
        is_async: false,
        is_comptime: false,
        extern_abi: null,
        is_export: false,
        is_attach: false,
    };
}

// `(var x: T = d, static this, ...)`: the params go into out; returns whether they end in C varargs `...`
attach fn params(this: parser&, out: std::vec<param>&) -> compile_error!bool {
    try this.expect("(");
    var c_varargs = false;
    while (!this.eat(")")) {
        if (this.eat("...")) {
            c_varargs = true;
            try this.expect(")");
            break;
        }
        val start = this.span();
        var (mutable, is_static, is_comptime) = (false, false, false);
        loop {
            if (this.eat_kw("var")) {
                mutable = true;
            } else if (this.eat_kw("static")) {
                is_static = true;
            } else if (this.eat_kw("comptime")) {
                is_comptime = true;
            } else {
                break;
            }
        }
        var name = "this";
        if (!this.eat_kw("this")) {
            name = (try this.ident()).name;
        }
        var t: ty? = null;
        if (this.eat(":")) {
            t = try this.parse_type();
        }
        var fallback: expr? = null;
        if (this.eat("=")) {
            fallback = try this.expr();
        }
        put(out, { name: name, ty: move t, fallback: move fallback, mutable: mutable, is_static: is_static, is_comptime: is_comptime, span: start.to(this.prev_span()) });
        if (!this.eat(",") && !this.is(")")) {
            return this.unexpected("',' or ')'");
        }
    }
    return c_varargs;
}

// ---------- types ----------

attach fn parse_type(this: parser&) -> compile_error!ty {
    return this.type_ext(false);
}

// a type; with stop_at_pack a trailing `...` is left for the caller (generic param bounds).
// Suffixes after E!T (& * ? [N] [..]) apply to the whole error union: E!T& is a reference to one,
// and the payload takes suffixes only in parentheses, E!(T&)
attach fn type_ext(this: parser&, stop_at_pack: bool) -> compile_error!ty {
    val start = this.span();
    var u: ty = { kind: type_kind::TUPLE({}), span: start };
    if (this.eat("!")) {
        val inner = try this.err_payload();
        val sp = start.to(inner.span);
        u = { kind: type_kind::ERROR_UNION(null, bx(move inner)), span: sp };
    } else {
        val t = try this.type_no_err(stop_at_pack, false);
        if (!this.eat("!")) {
            return t;
        }
        val rhs = try this.err_payload();
        val sp = start.to(rhs.span);
        u = { kind: type_kind::ERROR_UNION(bx(move t), bx(move rhs)), span: sp };
    }
    return this.type_suffixes(move u, start, stop_at_pack, false);
}

// the T of E!T: no suffixes of its own; E!F!T nests to the right
attach fn err_payload(this: parser&) -> compile_error!ty {
    val start = this.span();
    val a = try this.type_atom();
    if (!this.eat("!")) {
        return a;
    }
    val rhs = try this.err_payload();
    val sp = start.to(rhs.span);
    return { kind: type_kind::ERROR_UNION(bx(move a), bx(move rhs)), span: sp };
}

// in_cast: `x as T * 2` multiplies, so after `as` a `*`/`&` is only a suffix when no operand follows
attach fn type_no_err(this: parser&, stop_at_pack: bool, in_cast: bool) -> compile_error!ty {
    val start = this.span();
    val a = try this.type_atom();
    return this.type_suffixes(move a, start, stop_at_pack, in_cast);
}

// a type without suffixes: a tuple or parenthesized type, a fn type, a path, a comptime call
attach fn type_atom(this: parser&) -> compile_error!ty {
    val start = this.span();
    var t: type_kind = type_kind::TUPLE({});
    if (this.eat("(")) {
        var elems: std::vec<tuple_elem> = {};
        var trailing_comma = false;
        while (!this.eat(")")) {
            var name: str? = null;
            if (this.is_ident() && this.is_at(1, ":")) {
                name = (try this.ident()).name;
                this.bump();
            }
            put(&elems, { name: name, ty: try this.parse_type() });
            trailing_comma = this.eat(",");
            if (!trailing_comma && !this.is(")")) {
                return this.unexpected("',' or ')'");
            }
        }
        // (T) groups; a 1-tuple is (T,)
        if (elems.len == 1 && elems.at(0).name == null && !trailing_comma) {
            return copy elems.at(0).ty;
        }
        t = type_kind::TUPLE(move elems);
    } else if (this.is_kw("fn") || (this.is_kw("extern") && this.is_kw_at(2, "fn"))) {
        val extern_c = this.eat_kw("extern");
        if (extern_c) {
            this.bump(); // "C"
        }
        this.bump();
        try this.expect("(");
        var params: std::vec<ty> = {};
        var c_varargs = false;
        while (!this.eat(")")) {
            if (this.eat("...")) {
                c_varargs = true;
                continue;
            }
            put(&params, try this.parse_type());
            if (!this.eat(",") && !this.is(")")) {
                return this.unexpected("',' or ')'");
            }
        }
        var ret: ty = { kind: type_kind::TUPLE({}), span: start };
        if (this.eat("->")) {
            ret = try this.parse_type();
        } else {
            ret = { kind: type_kind::PATH(single_path("void", this.prev_span())), span: this.prev_span() };
        }
        t = type_kind::FN({ params: move params, c_varargs: c_varargs, ret: bx(move ret), extern_c: extern_c });
    } else if (this.is_type_name()) {
        val p = try this.path(true);
        if (this.is("(")) {
            // a comptime function returning a type
            val pspan = p.span;
            val args = try this.call_args();
            val callee: expr = { kind: expr_kind::PATH(move p), span: pspan };
            t = type_kind::EXPR(bx<expr>({ kind: expr_kind::CALL(bx(move callee), move args), span: start.to(this.prev_span()) }));
        } else {
            t = type_kind::PATH(move p);
        }
    } else {
        return this.unexpected("a type");
    }
    return { kind: move t, span: start.to(this.prev_span()) };
}

// the suffixes after a type: T* T& T? T... T[N] T[] T[..]
attach fn type_suffixes(this: parser&, first: ty, start: span, stop_at_pack: bool, in_cast: bool) -> compile_error!ty {
    var cur = move first;
    loop {
        // each step spans from the start, so (T) covers its parentheses
        cur.span = start.to(this.prev_span());
        if (this.is("*") && !(in_cast && this.starts_operand_at(1, false))) {
            this.bump();
            cur = { kind: type_kind::PTR(bx(move cur)), span: start.to(this.prev_span()) };
        } else if (this.is("&") && !(in_cast && this.starts_operand_at(1, false))) {
            this.bump();
            cur = { kind: type_kind::REF(bx(move cur)), span: start.to(this.prev_span()) };
        } else if (this.eat("?")) {
            cur = { kind: type_kind::OPTIONAL(bx(move cur)), span: start.to(this.prev_span()) };
        } else if (this.eat("??")) {
            // T?? lexes as the ?? operator: an optional of an optional
            val sp = cur.span;
            cur = { kind: type_kind::OPTIONAL(bx<ty>({ kind: type_kind::OPTIONAL(bx(move cur)), span: sp })), span: start.to(this.prev_span()) };
        } else if (this.is("...") && !stop_at_pack) {
            this.bump();
            cur = { kind: type_kind::PACK(bx(move cur)), span: start.to(this.prev_span()) };
        } else if (this.is("[") && !(this.is_kw_at(1, "var") || this.is_kw_at(1, "val"))) {
            // `[var`/`[val` opens a for loop's accumulator, not an array suffix
            this.bump();
            if (this.eat("..")) {
                try this.expect("]");
                cur = { kind: type_kind::SLICE(bx(move cur)), span: start.to(this.prev_span()) };
            } else if (this.eat("]")) {
                cur = { kind: type_kind::ARRAY(bx(move cur), null), span: start.to(this.prev_span()) };
            } else {
                val n = try this.expr();
                try this.expect("]");
                cur = { kind: type_kind::ARRAY(bx(move cur), bx(move n)), span: start.to(this.prev_span()) };
            }
        } else {
            return cur;
        }
    }
}

attach fn is_type_name(this: parser&) -> bool {
    val s = ident_of(this.tok()) ?? return false;
    return s == "error" || !is_keyword(s);
}

fn single_path(name: str, sp: span) -> path {
    var segs: std::vec<path_seg> = {};
    put(&segs, { name: name, args: null });
    return { segs: move segs, span: sp };
}

// a::b<T>::c. In types every `<` opens generic args; in expressions only after a generic name, or
// after a qualified name (ns::f<T>) when a call or `::` follows the `>` (a template from a C++ import
// is a generic name only the checker knows)
attach fn path(this: parser&, in_type: bool) -> compile_error!path {
    val start = this.span();
    var segs: std::vec<path_seg> = {};
    loop {
        val name = ident_of(this.tok()) ?? return this.unexpected("a name");
        if (name != "error" && is_keyword(name)) {
            return this.unexpected("a name");
        }
        this.bump();
        var args: std::vec<garg>? = null;
        if (this.is("<") && in_type) {
            args = try this.generic_args();
        } else if (this.is("<") && this.generics.get(name) != null) {
            args = this.try_generic_args();
        } else if (this.is("<") && segs.len > 0) {
            val save = this.pos;
            args = this.try_generic_args();
            if (args != null && !this.is("(") && !this.is("::")) {
                args = null;
                this.pos = save;
            }
        }
        put(&segs, { name: name, args: move args });
        if (this.is("::") && this.is_ident_at(1)) {
            this.bump();
        } else {
            break;
        }
    }
    return { segs: move segs, span: start.to(this.prev_span()) };
}

fn is_ident_tok(t: tok&) -> bool {
    match (*t) {
        .IDENT(s) => { return true; },
        default => { return false; },
    }
}

fn is_punct_tok(t: tok&, p: str) -> bool {
    match (*t) {
        .PUNCT(s) => { return s == p; },
        default => { return false; },
    }
}
