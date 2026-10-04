// The parser, continued: statements, expressions, closures and patterns (see parser.volt).
use std::mem;

// ---------- statements ----------

attach fn block(this: parser&) -> compile_error!block {
    val start = try this.expect("{");
    var stmts: std::vec<stmt> = {};
    loop {
        if (this.is("}")) {
            val c = this.line_col(this.pos);
            if (c != null && (c ?? 0) != this.indent(start.lo)) {
                this.suspect = true;
                this.suspect_open = start;
                this.suspect_close = this.span();
            }
            this.bump();
            break;
        }
        if (this.at_eof() || this.runs_into_item()) {
            return this.never_closed(start);
        }
        if (this.eat(";")) {
            continue;
        }
        put(&stmts, try this.stmt());
    }
    return { stmts: move stmts, span: start.to(this.prev_span()) };
}

// a block runs into the next item: a line at or left of the item's column that starts with a word
// only items start with
attach fn runs_into_item(this: parser&) -> bool {
    val c = this.line_col(this.pos) ?? return false;
    if (c > this.item_col) {
        return false;
    }
    val only: str[] = { "fn", "struct", "enum", "trait", "attach", "namespace", "internal", "public", "export", "extern" };
    for (k) in only {
        if (this.is_kw(k)) {
            return true;
        }
    }
    return false;
}

// a block opened at `open` reaches the next item or the end of the file. The brace most likely
// unclosed is one whose '}' didn't line up with it (that '}' closed it instead), else this one
attach fn never_closed(this: parser&, open: span) -> compile_error {
    var end = "the next item starts here";
    if (this.at_eof()) {
        end = "the file ends here";
    }
    val here = this.span();
    if (this.suspect) {
        this.suspect = false;
        val e = with_label(fails(this.suspect_open, "this '{' is never closed"), this.suspect_close, S("this '}' doesn't line up with it, but closes it"));
        return with_label(e, here, S(end));
    }
    return with_label(fails(open, "this '{' is never closed"), here, S(end));
}

// the indentation of the line holding byte lo
attach fn indent(this: parser&, lo: u32) -> usize {
    var line = @cast<usize>(lo);
    while (line > 0 && this.src[line - 1] != '\n') {
        line -= 1;
    }
    var n: usize = 0;
    while (line + n < this.src.len && (this.src[line + n] == ' ' || this.src[line + n] == '\t')) {
        n += 1;
    }
    return n;
}

// `[static] var|val name|(a, b) [: T] [= init];`
attach fn let_stmt(this: parser&, is_comptime: bool) -> compile_error!let_stmt {
    val start = this.span();
    val is_static = this.eat_kw("static");
    var mutable = true;
    if (!this.eat_kw("var")) {
        try this.expect_kw("val");
        mutable = false;
    }
    var p: pat = { kind: pat_kind::WILD, span: start };
    if (this.is("(")) {
        val s = this.span();
        this.bump();
        var elems: std::vec<pat> = {};
        while (!this.eat(")")) {
            val id = try this.ident();
            put(&elems, { kind: pat_kind::BIND(id.name), span: id.span });
            if (!this.eat(",") && !this.is(")")) {
                return this.unexpected("',' or ')'");
            }
        }
        p = { kind: pat_kind::TUPLE(move elems), span: s.to(this.prev_span()) };
    } else {
        val id = try this.ident();
        p = { kind: pat_kind::BIND(id.name), span: id.span };
    }
    var t: ty? = null;
    if (this.eat(":")) {
        t = try this.parse_type();
    }
    var init: expr? = null;
    if (this.eat("=")) {
        init = try this.expr();
    }
    try this.expect(";");
    return { mutable: mutable, is_comptime: is_comptime, is_static: is_static, pat: move p, ty: move t, init: move init, span: start.to(this.prev_span()) };
}

fn block_kw(s: str) -> bool {
    return s == "if" || s == "match" || s == "for" || s == "while" || s == "loop";
}

// if/match/for/while/loop, maybe after `comptime` or a `:label`
attach fn starts_block_stmt(this: parser&) -> bool {
    val s = ident_of(this.tok()) ?? "";
    if (block_kw(s)) {
        return true;
    }
    if (s == "comptime") {
        return block_kw(ident_of(this.tok_at(1)) ?? "");
    }
    if (this.is(":")) {
        return this.is_ident_at(1) && block_kw(ident_of(this.tok_at(2)) ?? "");
    }
    return false;
}

// an expression ending in a block, which needs no `;` as a statement
fn is_block_like(e: expr&) -> bool {
    match (e.kind) {
        .IF(x) => { return true; },
        .WHILE(l, c, b) => { return true; },
        .LOOP(l, b) => { return true; },
        .FOR(f) => { return true; },
        .MATCH(m) => { return true; },
        .BLOCK(l, b) => { return true; },
        default => { return false; },
    }
}

// one statement; an expression statement needs `;` unless it ends in a block
attach fn stmt(this: parser&) -> compile_error!stmt {
    val start = this.span();
    var kind: stmt_kind = stmt_kind::SUSPEND;
    if (this.is_kw("var") || this.is_kw("val") || (this.is_kw("static") && !this.is_kw_at(1, "this"))) {
        kind = stmt_kind::LET(try this.let_stmt(false));
    } else if (this.is_kw("comptime") && (this.is_kw_at(1, "var") || this.is_kw_at(1, "val"))) {
        this.bump();
        kind = stmt_kind::LET(try this.let_stmt(true));
    } else if (this.is_kw("defer") || this.is_kw("errdefer")) {
        val is_err = this.is_kw("errdefer");
        this.bump();
        var e: expr = { kind: expr_kind::NULL, span: start };
        if (this.is("{")) {
            val b = try this.block();
            val sp = b.span;
            e = { kind: expr_kind::BLOCK(null, move b), span: sp };
        } else {
            e = try this.expr();
            try this.expect(";");
        }
        if (is_err) {
            kind = stmt_kind::ERR_DEFER(move e);
        } else {
            kind = stmt_kind::DEFER(move e);
        }
    } else if (this.eat_kw("suspend")) {
        try this.expect(";");
        kind = stmt_kind::SUSPEND;
    } else if (this.eat_kw("resume")) {
        val e = try this.expr();
        try this.expect(";");
        kind = stmt_kind::RESUME(move e);
    } else if (this.is("{")) {
        val b = try this.block();
        val sp = b.span;
        kind = stmt_kind::EXPR({ kind: expr_kind::BLOCK(null, move b), span: sp });
    } else if (this.starts_block_stmt()) {
        // a statement that starts with if/match/for/while/loop ends at its '}':
        // `if (c) { .. } *p = 1;` is two statements, not a multiplication
        val e = try this.primary();
        this.eat(";");
        kind = stmt_kind::EXPR(move e);
    } else {
        val e = try this.expr();
        if (!this.eat(";") && !is_block_like(&e)) {
            return this.unexpected("';'");
        }
        kind = stmt_kind::EXPR(move e);
    }
    return { kind: move kind, span: start.to(this.prev_span()) };
}

// ---------- expressions ----------

// the operator of a compound assignment token (`+=` gives ADD)
fn assign_op(p: str) -> binop? {
    if (p == "+=") { return binop::ADD; }
    if (p == "-=") { return binop::SUB; }
    if (p == "*=") { return binop::MUL; }
    if (p == "/=") { return binop::DIV; }
    if (p == "%=") { return binop::REM; }
    if (p == "&=") { return binop::BITAND; }
    if (p == "|=") { return binop::BITOR; }
    if (p == "^=") { return binop::BITXOR; }
    if (p == "<<=") { return binop::SHL; }
    if (p == "+%=") { return binop::WADD; }
    if (p == "-%=") { return binop::WSUB; }
    if (p == "*%=") { return binop::WMUL; }
    return null;
}

// a full expression: an assignment (right-assoc, lowest precedence) or an operator expression
attach fn expr(this: parser&) -> compile_error!expr {
    val lhs = try this.bin(0);
    var is_assign = false;
    var op: binop? = null;
    if (this.is("=")) {
        is_assign = true;
    } else if (this.is(">") && this.glued_at(1) && this.is_at(1, ">=")) {
        // `>>=` lexes as `>` then a glued `>=`
        this.bump();
        is_assign = true;
        op = binop::SHR;
    } else {
        op = assign_op(punct_of(this.tok()) ?? "");
        is_assign = op != null;
    }
    if (is_assign) {
        this.bump();
        val rhs = try this.expr();
        val sp = lhs.span.to(rhs.span);
        return { kind: expr_kind::ASSIGN(op, bx(move lhs), bx(move rhs)), span: sp };
    }
    return move lhs;
}

struct infix_op {
    prec: u8;
    op: infix;
}

fn bin_at(prec: u8, op: binop) -> infix_op? {
    return { prec: prec, op: infix::BIN(op, 1) };
}

// the current token as an infix operator and its precedence (higher binds tighter); `>>` is two
// glued `>` tokens
attach fn infix(this: parser&) -> infix_op? {
    val w = ident_of(this.tok()) ?? "";
    if (w == "catch") {
        return { prec: PREC_ORELSE, op: infix::CATCH };
    }
    if (w == "as") {
        return { prec: 12, op: infix::AS };
    }
    val p = punct_of(this.tok()) ?? return null;
    if (p == "??") { return { prec: PREC_ORELSE, op: infix::OR_ELSE }; }
    if (p == "..") { return { prec: PREC_RANGE, op: infix::RANGE(false) }; }
    if (p == "..=") { return { prec: PREC_RANGE, op: infix::RANGE(true) }; }
    if (p == "||") { return bin_at(3, binop::OR); }
    if (p == "&&") { return bin_at(4, binop::AND); }
    if (p == "==") { return bin_at(5, binop::EQ); }
    if (p == "!=") { return bin_at(5, binop::NE); }
    if (p == "<") { return bin_at(5, binop::LT); }
    if (p == "<=") { return bin_at(5, binop::LE); }
    if (p == ">=") { return bin_at(5, binop::GE); }
    if (p == ">") {
        if (this.glued_at(1) && this.is_at(1, ">")) {
            return { prec: 9, op: infix::BIN(binop::SHR, 2) };
        }
        if (this.glued_at(1) && this.is_at(1, ">=")) {
            return null; // >>= assignment
        }
        return bin_at(5, binop::GT);
    }
    if (p == "|") { return bin_at(6, binop::BITOR); }
    if (p == "^") { return bin_at(7, binop::BITXOR); }
    if (p == "&") { return bin_at(8, binop::BITAND); }
    if (p == "<<") { return bin_at(9, binop::SHL); }
    if (p == "+") { return bin_at(10, binop::ADD); }
    if (p == "-") { return bin_at(10, binop::SUB); }
    if (p == "+%") { return bin_at(10, binop::WADD); }
    if (p == "-%") { return bin_at(10, binop::WSUB); }
    if (p == "*") { return bin_at(11, binop::MUL); }
    if (p == "/") { return bin_at(11, binop::DIV); }
    if (p == "%") { return bin_at(11, binop::REM); }
    if (p == "*%") { return bin_at(11, binop::WMUL); }
    return null;
}

// can the current token start an operand (for open ranges and break/return values)?
// `{` only counts when allowed: `0..100 {` is a range then a loop body, `return { a }` is a literal
attach fn starts_operand(this: parser&, brace: bool) -> bool {
    return this.starts_operand_at(0, brace);
}

attach fn starts_operand_at(this: parser&, n: usize, brace: bool) -> bool {
    match (*this.tok_at(n)) {
        .EOF => { return false; },
        .PUNCT(p) => {
            if (p == "{") {
                return brace;
            }
            return !(p == "]" || p == ")" || p == "}" || p == "," || p == ";" || p == "=>" || p == "=" || p == ":");
        },
        .IDENT(s) => { return !(s == "else" || s == "catch" || s == "as" || s == "in"); },
        default => { return true; },
    }
}

// precedence climbing over operators binding at least `min`. Binary ops are left-assoc; `??` and
// `catch` are right-assoc, and a range's end is optional (`a..`)
attach fn bin(this: parser&, min: u8) -> compile_error!expr {
    var lhs = try this.unary();
    loop {
        val io = this.infix() ?? break;
        if (io.prec < min) {
            break;
        }
        val start = lhs.span;
        val prec = io.prec;
        match (io.op) {
            .BIN(op, n) => {
                for (k) in 0..n {
                    this.bump();
                }
                val rhs = try this.bin(prec + 1);
                lhs = { kind: expr_kind::BINARY(op, bx(move lhs), bx(move rhs)), span: start.to(this.prev_span()) };
            },
            .OR_ELSE => {
                this.bump();
                val rhs = try this.bin(prec);
                lhs = { kind: expr_kind::OR_ELSE(bx(move lhs), bx(move rhs)), span: start.to(this.prev_span()) };
            },
            .CATCH => {
                this.bump();
                var cap: catch_cap? = null;
                if (this.eat("|")) {
                    val c = try this.ident();
                    try this.expect("|");
                    cap = { name: c.name, span: c.span };
                }
                var handler: expr = { kind: expr_kind::NULL, span: start };
                if (this.is("{")) {
                    val b = try this.block();
                    val sp = b.span;
                    handler = { kind: expr_kind::BLOCK(null, move b), span: sp };
                } else {
                    handler = try this.bin(prec);
                }
                lhs = { kind: expr_kind::CATCH(bx(move lhs), cap, bx(move handler)), span: start.to(this.prev_span()) };
            },
            .RANGE(incl) => {
                this.bump();
                var rhs: std::box<expr>? = null;
                if (this.starts_operand(false)) {
                    rhs = bx(try this.bin(prec + 1));
                }
                lhs = { kind: expr_kind::RANGE(bx(move lhs), move rhs, incl), span: start.to(this.prev_span()) };
            },
            .AS => {
                this.bump();
                val t = try this.type_no_err(false, true);
                lhs = { kind: expr_kind::CAST(bx(move lhs), move t), span: start.to(this.prev_span()) };
            },
        }
    }
    return move lhs;
}

fn unop_of(p: str) -> unop? {
    if (p == "-") { return unop::NEG; }
    if (p == "!") { return unop::NOT; }
    if (p == "~") { return unop::BITNOT; }
    if (p == "&") { return unop::ADDR; }
    if (p == "*") { return unop::DEREF; }
    return null;
}

// prefix operators and try/await/async/move/copy, then a postfix expression
attach fn unary(this: parser&) -> compile_error!expr {
    val start = this.span();
    val op = unop_of(punct_of(this.tok()) ?? "");
    if (op) {
        this.bump();
        val e = try this.unary();
        val sp = start.to(e.span);
        return { kind: expr_kind::UNARY(op, bx(move e)), span: sp };
    }
    val w = ident_of(this.tok()) ?? "";
    if (w == "try" || w == "await" || w == "async" || w == "move" || w == "copy") {
        this.bump();
        if (w == "copy" && (this.is(")") || this.is(","))) {
            return fails(start, "copy needs a value: copy x (a struct copies field by field; there's no copy derive)");
        }
        val e = try this.unary();
        val sp = start.to(e.span);
        val b = bx(move e);
        if (w == "try") {
            return { kind: expr_kind::TRY(move b), span: sp };
        }
        if (w == "await") {
            return { kind: expr_kind::AWAIT(move b), span: sp };
        }
        if (w == "async") {
            return { kind: expr_kind::ASYNC(move b), span: sp };
        }
        if (w == "move") {
            return { kind: expr_kind::MOVE(move b), span: sp };
        }
        return { kind: expr_kind::COPY(move b), span: sp };
    }
    return this.postfix();
}

// calls, indexing, fields (a.b, a.0, a.f<T>, p->b) and `++`/`--` after a primary
attach fn postfix(this: parser&) -> compile_error!expr {
    var e = try this.primary();
    loop {
        val start = e.span;
        if (this.is("(")) {
            val args = try this.call_args();
            e = { kind: expr_kind::CALL(bx(move e), move args), span: start.to(this.prev_span()) };
        } else if (this.is("[") && !(this.is_kw_at(1, "var") || this.is_kw_at(1, "val"))) {
            // `[var`/`[val` opens a for loop's accumulator, not an index
            this.bump();
            val idx = try this.expr();
            try this.expect("]");
            e = { kind: expr_kind::INDEX(bx(move e), bx(move idx)), span: start.to(this.prev_span()) };
        } else if (this.is(".") && this.field_name_at(1) != null) {
            this.bump();
            match (*this.tok()) {
                .INT(v) => {
                    // written exactly as its decimal value: t.01 and t.0x1 are errors
                    val sp = this.span();
                    if (@cast<u128>(sp.hi - sp.lo) != decimal_len(v)) {
                        return fails(sp, "a tuple index is a plain decimal number, like t.1");
                    }
                },
                default => {},
            }
            val name = this.field_name_at(0) ?? "";
            this.bump();
            val args = this.method_generic_args(name);
            e = { kind: expr_kind::FIELD(bx(move e), name, move args), span: start.to(this.prev_span()) };
        } else if (this.is("->") && this.is_ident_at(1)) {
            // p->name is (*p).name
            this.bump();
            val name = (try this.ident()).name;
            val args = this.method_generic_args(name);
            val sp = start.to(this.prev_span());
            e = { kind: expr_kind::FIELD(bx<expr>({ kind: expr_kind::UNARY(unop::DEREF, bx(move e)), span: start }), name, move args), span: sp };
        } else if (this.is("++") || this.is("--")) {
            val inc = this.is("++");
            this.bump();
            e = { kind: expr_kind::INC_DEC(bx(move e), inc), span: start.to(this.prev_span()) };
        } else {
            return move e;
        }
    }
}

// how many decimal digits v has
fn decimal_len(v: u128) -> u128 {
    var n: u128 = 1;
    var x = v;
    while (x >= 10) {
        x = x / 10;
        n += 1;
    }
    return n;
}

// a name or tuple index after '.': its source text (a tuple index is checked to be plain decimal first)
attach fn field_name_at(this: parser&, n: usize) -> str? {
    match (*this.tok_at(n)) {
        .IDENT(s) => { return s; },
        .INT(v) => {
            val i = this.pos + n;
            val sp = this.toks.at(i).span;
            return this.src[sp.lo..sp.hi];
        },
        default => { return null; },
    }
}

attach fn call_args(this: parser&) -> compile_error!std::vec<expr> {
    try this.expect("(");
    var args: std::vec<expr> = {};
    while (!this.eat(")")) {
        put(&args, try this.expr());
        if (!this.eat(",") && !this.is(")")) {
            return this.unexpected("',' or ')'");
        }
    }
    return move args;
}

// `@name<T>(args)`: only @cast takes `<...>`, each arg may be a type or a value, and the parentheses are
// optional
attach fn builtin(this: parser&) -> compile_error!expr {
    val start = this.span();
    var name = "";
    match (*this.tok()) {
        .BUILTIN(s) => { name = s; },
        default => {},
    }
    this.bump();
    var generics: std::vec<garg> = {};
    if (this.is("<") && (name == "cast" || name == "bitcast" || name == "cpp")) {
        generics = try this.generic_args();
    }
    var args: std::vec<garg>? = null;
    if (this.eat("(")) {
        var list: std::vec<garg> = {};
        while (!this.eat(")")) {
            put(&list, try this.generic_arg(")"));
            if (!this.eat(",") && !this.is(")")) {
                return this.unexpected("',' or ')'");
            }
        }
        args = move list;
    }
    return { kind: expr_kind::BUILTIN(name, move generics, move args), span: start.to(this.prev_span()) };
}

// an optional `:name` loop or block label
attach fn label(this: parser&) -> compile_error!(str?) {
    if (this.is(":") && this.is_ident_at(1)) {
        this.bump();
        return (try this.ident()).name;
    }
    return null;
}

// a literal, name, `(...)`, `{...}` literal, closure, label, `.VARIANT`, open range, or a keyword
// expression (return, break, if, match, loops...)
attach fn primary(this: parser&) -> compile_error!expr {
    val start = this.span();
    var kind: expr_kind = expr_kind::NULL;
    var done = false;
    match (*this.tok()) {
        .INT(v) => {
            kind = expr_kind::INT(v);
            done = true;
        },
        .FLOAT(v) => {
            kind = expr_kind::FLOAT(v);
            done = true;
        },
        .CHAR(v) => {
            kind = expr_kind::CHAR(v);
            done = true;
        },
        .STR(s) => {
            kind = expr_kind::STR(copy s);
            done = true;
        },
        default => {},
    }
    if (done) {
        this.bump();
        return { kind: move kind, span: start.to(this.prev_span()) };
    }
    if (this.is_builtin_tok()) {
        return this.builtin();
    }
    // `()` is the empty tuple, `(e)` groups, and a comma makes a tuple: `(e,)`
    if (this.is("(")) {
        this.bump();
        if (this.eat(")")) {
            return { kind: expr_kind::TUPLE({}), span: start.to(this.prev_span()) };
        }
        val first = try this.expr();
        if (this.eat(")")) {
            return move first;
        }
        var elems: std::vec<expr> = {};
        put(&elems, move first);
        while (this.eat(",")) {
            if (this.is(")")) {
                break;
            }
            put(&elems, try this.expr());
        }
        try this.expect(")");
        return { kind: expr_kind::TUPLE(move elems), span: start.to(this.prev_span()) };
    }
    if (this.is("{")) {
        this.bump();
        var entries: std::vec<lit_entry> = {};
        while (!this.eat("}")) {
            var name: str? = null;
            if (this.is_ident() && this.is_at(1, ":")) {
                name = (try this.ident()).name;
                this.bump();
            }
            var value = try this.expr();
            // { x; n }: n copies of x
            if (entries.len == 0 && name == null && this.eat(";")) {
                var n = try this.expr();
                try this.expect("}");
                return { kind: expr_kind::REPEAT(bx(move value), bx(move n)), span: start.to(this.prev_span()) };
            }
            put(&entries, { name: name, value: move value });
            if (!this.eat(",") && !this.is("}")) {
                return this.unexpected("',' or '}'");
            }
        }
        return { kind: expr_kind::LITERAL(move entries), span: start.to(this.prev_span()) };
    }
    if (this.is("|") || this.is("||")) {
        return this.closure();
    }
    if (this.is(":") && this.is_ident_at(1)) {
        val lab = try this.label();
        if (this.is("{")) {
            val b = try this.block();
            return { kind: expr_kind::BLOCK(lab, move b), span: start.to(this.prev_span()) };
        }
        if (!(this.is_kw("for") || this.is_kw("while") || this.is_kw("loop"))) {
            return this.unexpected("for, while or loop after a label");
        }
        return this.loop_expr(lab, false);
    }
    if (this.is(".") && this.is_ident_at(1)) {
        this.bump();
        val n = (try this.ident()).name;
        return { kind: expr_kind::DOT_VARIANT(n), span: start.to(this.prev_span()) };
    }
    if (this.is("..") || this.is("..=")) {
        val incl = this.is("..=");
        this.bump();
        var rhs: std::box<expr>? = null;
        if (this.starts_operand(false)) {
            rhs = bx(try this.bin(PREC_RANGE + 1));
        }
        return { kind: expr_kind::RANGE(null, move rhs, incl), span: start.to(this.prev_span()) };
    }
    val s = ident_of(this.tok()) ?? return this.unexpected("an expression");
    if (s == "true" || s == "false") {
        this.bump();
        return { kind: expr_kind::BOOL(s == "true"), span: start.to(this.prev_span()) };
    }
    if (s == "null") {
        this.bump();
        return { kind: expr_kind::NULL, span: start.to(this.prev_span()) };
    }
    if (s == "this") {
        this.bump();
        return { kind: expr_kind::THIS, span: start.to(this.prev_span()) };
    }
    if (s == "error" && !this.is_at(1, "::")) {
        this.bump();
        return { kind: expr_kind::ERROR_ANY, span: start.to(this.prev_span()) };
    }
    if (s == "return") {
        this.bump();
        var v: std::box<expr>? = null;
        if (this.starts_operand(true)) {
            v = bx(try this.expr());
        }
        return { kind: expr_kind::RETURN(move v), span: start.to(this.prev_span()) };
    }
    if (s == "break") {
        this.bump();
        val lab = try this.label();
        var v: std::box<expr>? = null;
        if (this.starts_operand(true)) {
            v = bx(try this.expr());
        }
        return { kind: expr_kind::BREAK(lab, move v), span: start.to(this.prev_span()) };
    }
    if (s == "continue") {
        this.bump();
        val lab = try this.label();
        return { kind: expr_kind::CONTINUE(lab), span: start.to(this.prev_span()) };
    }
    if (s == "comptime") {
        this.bump();
        if (!(this.is_kw("if") || this.is_kw("match") || this.is_kw("for"))) {
            return this.unexpected("if, match or for after comptime");
        }
        return this.loop_expr(null, true);
    }
    if (block_kw(s)) {
        return this.loop_expr(null, false);
    }
    if (!is_keyword(s) || s == "error") {
        val p = try this.path(false);
        return { kind: expr_kind::PATH(move p), span: start.to(this.prev_span()) };
    }
    return this.unexpected("an expression");
}

attach fn is_builtin_tok(this: parser&) -> bool {
    match (*this.tok()) {
        .BUILTIN(s) => { return true; },
        default => { return false; },
    }
}

// if / match / for / while / loop, with an optional label and comptime flag
attach fn loop_expr(this: parser&, lab: str?, is_comptime: bool) -> compile_error!expr {
    val start = this.span();
    var kind: expr_kind = expr_kind::NULL;
    if (this.eat_kw("if")) {
        try this.expect("(");
        val cond = try this.expr();
        try this.expect(")");
        val then = try this.block();
        var els: std::box<expr>? = null;
        if (this.eat_kw("else")) {
            if (this.is_kw("if")) {
                els = bx(try this.loop_expr(null, is_comptime));
            } else if (this.is_kw("comptime") && this.is_kw_at(1, "if")) {
                // `else comptime if`: that branch is decided in the compiler (after `comptime if`, so is a plain `else if`)
                this.bump();
                els = bx(try this.loop_expr(null, true));
            } else {
                val b = try this.block();
                val sp = b.span;
                els = bx<expr>({ kind: expr_kind::BLOCK(null, move b), span: sp });
            }
        }
        kind = expr_kind::IF({ cond: bx(move cond), then: move then, els: move els, is_comptime: is_comptime });
    } else if (this.eat_kw("match")) {
        try this.expect("(");
        val scrut = try this.expr();
        try this.expect(")");
        try this.expect("{");
        var arms: std::vec<arm> = {};
        while (!this.eat("}")) {
            val astart = this.span();
            val p = try this.pat();
            var guard: expr? = null;
            if (this.eat_kw("if")) {
                guard = try this.expr();
            }
            try this.expect("=>");
            var body: expr = { kind: expr_kind::NULL, span: astart };
            if (this.is("{")) {
                val b = try this.block();
                val sp = b.span;
                body = { kind: expr_kind::BLOCK(null, move b), span: sp };
            } else {
                body = try this.expr();
            }
            put(&arms, { pat: move p, guard: move guard, body: move body, span: astart.to(this.prev_span()) });
            if (!this.eat(",") && !this.eat(";") && !this.is("}")) {
                return this.unexpected("',' or '}' after match arm");
            }
        }
        kind = expr_kind::MATCH({ scrut: bx(move scrut), arms: move arms, is_comptime: is_comptime });
    } else if (this.eat_kw("while")) {
        try this.expect("(");
        val cond = try this.expr();
        try this.expect(")");
        kind = expr_kind::WHILE(lab, bx(move cond), try this.block());
    } else if (this.eat_kw("loop")) {
        kind = expr_kind::LOOP(lab, try this.block());
    } else if (this.eat_kw("for")) {
        try this.expect("(");
        var bindings: std::vec<binding> = {};
        while (!this.eat(")")) {
            val id = try this.ident();
            val by_ref = this.eat("&");
            put(&bindings, { name: id.name, by_ref: by_ref, span: id.span });
            if (!this.eat(",") && !this.is(")")) {
                return this.unexpected("',' or ')'");
            }
        }
        try this.expect_kw("in");
        val iter = try this.expr();
        var map: expr? = null;
        if (this.eat("=>")) {
            map = try this.expr();
        }
        var acc: let_stmt? = null;
        if (this.is("[")) {
            this.bump();
            val astart = this.span();
            var mutable = true;
            if (!this.eat_kw("var")) {
                try this.expect_kw("val");
                mutable = false;
            }
            val id = try this.ident();
            var t: ty? = null;
            if (this.eat(":")) {
                t = try this.parse_type();
            }
            var init: expr? = null;
            if (this.eat("=")) {
                init = try this.expr();
            }
            try this.expect("]");
            acc = {
                mutable: mutable,
                is_comptime: false,
                is_static: false,
                pat: { kind: pat_kind::BIND(id.name), span: id.span },
                ty: move t,
                init: move init,
                span: astart.to(this.prev_span()),
            };
        }
        val body = try this.block();
        kind = expr_kind::FOR(bx<for_loop>({ label: lab, bindings: move bindings, iter: move iter, map: move map, acc: move acc, body: move body, is_comptime: is_comptime }));
    } else {
        return this.unexpected("for, while or loop after a label");
    }
    return { kind: move kind, span: start.to(this.prev_span()) };
}

// `|a, b&, move c| (params) -> R { body }`: captures copy unless marked `&` (by reference) or `move`;
// `|c| <T: type>(x: T) { }` is generic
attach fn closure(this: parser&) -> compile_error!expr {
    val start = this.span();
    var caps: std::vec<capture> = {};
    if (!this.eat("||")) {
        try this.expect("|");
        while (!this.eat("|")) {
            val cs = this.span();
            val mode_move = this.eat_kw("move");
            val name = (try this.ident()).name;
            var mode = cap_mode::COPY;
            if (mode_move) {
                mode = cap_mode::MOVE;
            } else if (this.eat("&")) {
                mode = cap_mode::REF;
            }
            put(&caps, { name: name, mode: mode, span: cs.to(this.prev_span()) });
            if (!this.eat(",") && !this.is("|")) {
                return this.unexpected("',' or '|'");
            }
        }
    }
    var gps: std::vec<generic_param> = {};
    if (this.is("<")) {
        gps = try this.generic_params();
    }
    var ps: std::vec<param> = {};
    try this.params(&ps);
    var ret: ty? = null;
    if (this.eat("->")) {
        ret = try this.parse_type();
    }
    val body = try this.block();
    return { kind: expr_kind::CLOSURE({ caps: move caps, generics: move gps, params: move ps, ret: move ret, body: move body }), span: start.to(this.prev_span()) };
}

// whether a literal pattern starts here (a number, maybe negative, char, string, true, false, null)
attach fn is_lit_tok(this: parser&) -> bool {
    match (*this.tok()) {
        .INT(v) => { return true; },
        .FLOAT(v) => { return true; },
        .CHAR(v) => { return true; },
        .STR(s) => { return true; },
        default => {},
    }
    if (this.is("-")) {
        match (*this.tok_at(1)) {
            .INT(v) => { return true; },
            .FLOAT(v) => { return true; },
            default => {},
        }
    }
    return this.is_kw("true") || this.is_kw("false") || this.is_kw("null");
}

// a match pattern. A bare name binds (`n`, or `n&` by reference); a constructor needs `.X`, a
// qualified path or parentheses
attach fn pat(this: parser&) -> compile_error!pat {
    val start = this.span();
    if (this.eat_kw("default") || this.is_kw("_")) {
        if (this.is_kw("_")) {
            this.bump();
        }
        return { kind: pat_kind::WILD, span: start.to(this.prev_span()) };
    }
    if (this.is(".") && this.is_ident_at(1)) {
        this.bump();
        val n = (try this.ident()).name;
        val args = try this.pat_args();
        return { kind: pat_kind::CTOR(ctor_path::DOT(n), move args), span: start.to(this.prev_span()) };
    }
    if (this.eat("(")) {
        var elems: std::vec<pat> = {};
        while (!this.eat(")")) {
            put(&elems, try this.pat());
            if (!this.eat(",") && !this.is(")")) {
                return this.unexpected("',' or ')'");
            }
        }
        return { kind: pat_kind::TUPLE(move elems), span: start.to(this.prev_span()) };
    }
    if (this.is_lit_tok()) {
        val lo = try this.unary();
        if (this.is("..") || this.is("..=")) {
            val incl = this.is("..=");
            this.bump();
            val hi = try this.unary();
            return { kind: pat_kind::RANGE(move lo, move hi, incl), span: start.to(this.prev_span()) };
        }
        return { kind: pat_kind::LIT(move lo), span: start.to(this.prev_span()) };
    }
    val p = try this.path(false);
    if (this.is("(")) {
        val args = try this.pat_args();
        return { kind: pat_kind::CTOR(ctor_path::PATH(move p), move args), span: start.to(this.prev_span()) };
    }
    if (p.segs.len == 1 && p.segs.at(0).args == null) {
        if (this.eat("&")) {
            return { kind: pat_kind::BIND_REF(p.segs.at(0).name), span: start.to(this.prev_span()) };
        }
        return { kind: pat_kind::BIND(p.segs.at(0).name), span: start.to(this.prev_span()) };
    }
    return { kind: pat_kind::CTOR(ctor_path::PATH(move p), null), span: start.to(this.prev_span()) };
}

attach fn pat_args(this: parser&) -> compile_error!(std::vec<pat>?) {
    if (!this.eat("(")) {
        return null;
    }
    var args: std::vec<pat> = {};
    while (!this.eat(")")) {
        put(&args, try this.pat());
        if (!this.eat(",") && !this.is(")")) {
            return this.unexpected("',' or ')'");
        }
    }
    return move args;
}
