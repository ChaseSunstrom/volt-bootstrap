// lexer: generate a large source text in a C-like toy language, tokenize it ten times, and count the
// tokens by kind (plus a checksum of the identifiers' lengths); Volt scans a str by index in a lexer
// whose next() makes it an iterator, and a token is an enum whose variants carry str slices of the
// text, taken apart with match
use std::io;
use std::text;

enum token {
    IDENT: str,
    KEYWORD: str,
    INT: str,
    FLOAT: str,
    STRING: str,
    OP: str,
    PUNCT: str,
    COMMENT: str,
    ERROR: str,
}

struct lexer {
    src: str;
    pos: usize = 0;
}

fn is_keyword(word: str) -> bool {
    return match (word) {
        "fn" => true,
        "let" => true,
        "if" => true,
        "else" => true,
        "while" => true,
        "for" => true,
        "return" => true,
        "struct" => true,
        "true" => true,
        "false" => true,
        default => false,
    };
}

fn is_punct(c: u8) -> bool {
    return c == '(' || c == ')' || c == '{' || c == '}' || c == '[' || c == ']' || c == ';' || c == ',' || c == '.';
}

attach fn at(this: lexer&, i: usize, c: u8) -> bool {
    return i < this.src.len && this.src[i] == c;
}

attach fn digit_at(this: lexer&, i: usize) -> bool {
    return i < this.src.len && this.src[i].is_digit();
}

// the next token, or null at the end (which makes a lexer an iterator)
attach fn next(this: lexer&) -> token? {
    val s = this.src;
    val n = s.len;
    var p = this.pos;
    while (p < n && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n' || s[p] == '\r')) {
        p += 1;
    }
    val start = p;
    if (p == n) {
        this.pos = p;
        return null;
    }
    val c = s[p];
    p += 1;
    if (c.is_alpha() || c == '_') {
        while (p < n && (s[p].is_alnum() || s[p] == '_')) {
            p += 1;
        }
        this.pos = p;
        val word = s[start..p];
        if (is_keyword(word)) {
            return token::KEYWORD(word);
        }
        return token::IDENT(word);
    }
    if (c.is_digit()) {
        var float = false;
        while (this.digit_at(p)) {
            p += 1;
        }
        if (this.at(p, '.') && this.digit_at(p + 1)) {
            float = true;
            p += 1;
            while (this.digit_at(p)) {
                p += 1;
            }
        }
        if (this.at(p, 'e') || this.at(p, 'E')) {
            var q = p + 1;
            if (this.at(q, '+') || this.at(q, '-')) {
                q += 1;
            }
            if (this.digit_at(q)) {
                float = true;
                p = q;
                while (this.digit_at(p)) {
                    p += 1;
                }
            }
        }
        this.pos = p;
        if (float) {
            return token::FLOAT(s[start..p]);
        }
        return token::INT(s[start..p]);
    }
    if (c == '"') {
        while (p < n && s[p] != '"') {
            if (s[p] == '\\' && p + 1 < n) {
                p += 2;
            } else {
                p += 1;
            }
        }
        if (p < n) {
            p += 1;
        }
        this.pos = p;
        return token::STRING(s[start..p]);
    }
    if (c == '/' && this.at(p, '/')) {
        while (p < n && s[p] != '\n') {
            p += 1;
        }
        this.pos = p;
        return token::COMMENT(s[start..p]);
    }
    if (c == '/' && this.at(p, '*')) {
        p += 1;
        while (p + 1 < n && !(s[p] == '*' && s[p + 1] == '/')) {
            p += 1;
        }
        if (p + 1 < n) {
            p += 2;
        } else {
            p = n;
        }
        this.pos = p;
        return token::COMMENT(s[start..p]);
    }
    if (is_punct(c)) {
        this.pos = p;
        return token::PUNCT(s[start..p]);
    }
    if (c == '=' || c == '!' || c == '<' || c == '>' || c == '+' || c == '*' || c == '/' || c == '%') {
        if (this.at(p, '=')) {
            p += 1; // ==, !=, <=, >=, +=, *=, /=, %=
        }
    } else if (c == '-') {
        if (this.at(p, '=') || this.at(p, '>')) {
            p += 1;
        }
    } else if (c == '&' || c == '|') {
        if (this.at(p, c)) {
            p += 1; // && and ||
        }
    } else {
        this.pos = p;
        return token::ERROR(s[start..p]);
    }
    this.pos = p;
    return token::OP(s[start..p]);
}

// ---- the source text ----

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

val NAMES: str[] = { "count", "index", "value", "node", "buf", "len", "total", "x", "y", "result", "item", "next_one", "left", "right", "data", "i" };
val WORDS: str[] = { "the", "loop", "ends", "when", "it", "reaches", "zero", "todo" };
val PIECES: str[] = { "hello", "world", "\\n", "\\t", "\\\"", "\\\\", " ", "value: " };
val OPS: str[] = { "+", "-", "*", "/", "%" };
val CMPS: str[] = { "==", "!=", "<", "<=", ">", ">=" };

fn gen_ident(b: std::string&) -> void {
    val r = next();
    b.append(NAMES[@cast<usize>(r % 16)]);
    if ((r >> 8) % 4 == 0) {
        b.push('_');
        b.append_uint((r >> 16) % 1000);
    }
}

fn gen_int(b: std::string&) -> void {
    b.append_uint(next() % 100000);
}

fn gen_float(b: std::string&) -> void {
    val r = next();
    b.append_uint(r % 1000);
    b.push('.');
    b.append_uint((r >> 20) % 1000);
    if ((r >> 40) % 4 == 0) {
        b.push('e');
        b.append_uint((r >> 50) % 20);
    }
}

fn gen_string(b: std::string&) -> void {
    val r = next();
    b.push('"');
    for (k) in 0..1 + r % 4 {
        b.append(PIECES[@cast<usize>((r >> (8 + 3 * k)) % 8)]);
    }
    b.push('"');
}

fn gen_words(b: std::string&) -> void {
    val r = next();
    for (k) in 0..2 + r % 6 {
        b.push(' ');
        b.append(WORDS[@cast<usize>((r >> (8 + 3 * k)) % 8)]);
    }
}

fn gen_expr(b: std::string&) -> void {
    val r = next();
    match (r % 4) {
        0 => gen_ident(b),
        1 => gen_int(b),
        2 => gen_float(b),
        default => {
            gen_ident(b);
            b.push(' ');
            b.append(OPS[@cast<usize>((r >> 8) % 5)]);
            b.push(' ');
            gen_int(b);
        },
    }
}

fn gen_statement(b: std::string&) -> void {
    val r = next();
    match (r % 8) {
        0 => {
            b.append("let ");
            gen_ident(b);
            b.append(" = ");
            gen_expr(b);
            b.append(";\n");
        },
        1 => {
            b.append("if (");
            gen_expr(b);
            b.push(' ');
            b.append(CMPS[@cast<usize>((r >> 8) % 6)]);
            b.push(' ');
            gen_expr(b);
            b.append(") {\n    ");
            gen_ident(b);
            b.append(" = ");
            gen_expr(b);
            b.append(";\n} else {\n    return ");
            gen_expr(b);
            b.append(";\n}\n");
        },
        2 => {
            b.append("while (");
            gen_ident(b);
            b.push(' ');
            b.append(CMPS[@cast<usize>((r >> 8) % 6)]);
            b.push(' ');
            gen_int(b);
            b.append(" && ");
            gen_ident(b);
            b.append(" != ");
            gen_int(b);
            b.append(" || !");
            gen_ident(b);
            b.append(") {\n    ");
            gen_ident(b);
            b.append(" += ");
            gen_int(b);
            b.append(";\n}\n");
        },
        3 => {
            b.append("return ");
            gen_string(b);
            b.append(";\n");
        },
        4 => {
            b.append("//");
            gen_words(b);
            b.push('\n');
        },
        5 => {
            b.append("/*");
            gen_words(b);
            b.append(" */\n");
        },
        6 => {
            gen_ident(b);
            b.push('(');
            gen_expr(b);
            b.append(", ");
            gen_expr(b);
            b.append(");\n");
        },
        default => {
            b.append("fn ");
            gen_ident(b);
            b.push('(');
            gen_ident(b);
            b.append(", ");
            gen_ident(b);
            b.append(") -> ");
            gen_ident(b);
            b.append(" {\n    let ");
            gen_ident(b);
            b.append(" = ");
            gen_float(b);
            b.append(" * ");
            gen_ident(b);
            b.append(" - ");
            gen_int(b);
            b.append(";\n}\n");
        },
    }
}

fn main() -> void {
    val n = @cast<usize>((std::process::arg(1) ?? "33554432").parse_int() catch 33554432);
    var src: std::string = {};
    while (src.len() < n) {
        gen_statement(&src);
    }
    var counts: usize[9];
    var total: usize = 0;
    var check: u64 = 0;
    for (pass) in 0..10 {
        var lx: lexer = { src: src.as_str() };
        for (t) in lx {
            total += 1;
            match (t) {
                .IDENT(name) => {
                    counts[0] += 1;
                    check = check *% 31 +% @cast<u64>(name.len);
                },
                .KEYWORD(_) => counts[1] += 1,
                .INT(_) => counts[2] += 1,
                .FLOAT(_) => counts[3] += 1,
                .STRING(_) => counts[4] += 1,
                .OP(_) => counts[5] += 1,
                .PUNCT(_) => counts[6] += 1,
                .COMMENT(_) => counts[7] += 1,
                .ERROR(_) => counts[8] += 1,
            }
        }
    }
    val names: str[] = { "ident", "keyword", "int", "float", "string", "op", "punct", "comment", "error" };
    std::println("{} bytes, {} tokens", src.len(), total);
    for (name, k) in names {
        std::println("{} {}", name, counts[k]);
    }
    std::println("identifier checksum {}", check);
}
