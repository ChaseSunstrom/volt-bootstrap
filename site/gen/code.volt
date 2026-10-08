// Code blocks as Expressive Code frames, highlighted as Shiki highlights them with the site's themes:
// Volt by the rules of the VS Code extension's grammar (editors/vscode/syntaxes/volt.tmLanguage.json),
// mirrored here pattern by pattern; sh, toml and plain text as Shiki colours them; the other
// languages by their keywords, types, strings, numbers and comments. Each character gets a colour,
// and a line is its runs of one colour. The first frame on a page brings Expressive Code's
// stylesheet and script.
use std::fmt;
use std::html;
use std::json;

// the colours: Expressive Code's dark (--0) and light (--1) values for each
val FG: u8 = 0;
val KW: u8 = 1;
val TY: u8 = 2;
val FN: u8 = 3;
val STR: u8 = 4;
val NUM: u8 = 5;
val COM: u8 = 6;
val PLAIN: u8 = 7;

val STYLES: str[8] = {
    "--0:#E6E1FF;--1:#1B1538",
    "--0:#C4B5FF;--1:#5A2EE0",
    "--0:#9FB8FF;--1:#2E4FC4",
    "--0:#FFFFFF;--1:#120D2C",
    "--0:#F5B38A;--1:#9C4615",
    "--0:#7FD8C9;--1:#0D6B5F",
    "--0:#8C86B2;--1:#5F5983",
    "--0:#e6e1ff;--1:#1b1538",
};

// what carries over from one line to the next: inside a block comment or a string
struct carry {
    comment: bool = false;
    triple: bool = false;      // a """ string
    raw_triple: bool = false;  // an r""" string
    quoted: bool = false;      // a "..." string left open
    continued: bool = false;   // sh: the line before ended in \
}

// a frame (site/theme/code.html); component: as Starlight's Code component renders it (std
// reference pages): wrapped, the longest line's length given
fn code_frame(th: theme&, info: str, body: str, first: bool, component: bool, out: std::string&) -> void {
    var lang = (info.split_once(" ") ?? (info, "")).0;
    if (lang.len == 0) {
        lang = "plaintext";
    }
    val terminal = lang == "sh" || lang == "bash" || lang == "shell" || lang == "console";
    var lines: std::vec<str> = {};
    for (l&) in body.lines().items() {
        lines.push(l.trim_end());
    }

    // a first line that's a comment naming a file is the frame's title
    var title: str? = null;
    if (lines.len > 0) {
        title = file_title(*lines.at(0));
        if (title) {
            lines.remove(0);
        }
    }
    var widest: usize = 0;
    for (l&) in lines.items() {
        val n = utf8_len(*l);
        if (n > widest) {
            widest = n;
        }
    }
    var d = std::json::object();
    d.set("component", std::json::boolean(component));
    d.set("first", std::json::boolean(first));
    d.set("title", std::json::string(title ?? ""));
    d.set("caption", std::json::boolean(title != null || terminal));
    d.set("terminal", std::json::boolean(terminal));
    d.set("lang", std::json::string(lang));
    d.set("widest", std::json::number(@cast<f64>(widest)));
    var ls = std::json::array();
    var c: carry = {};
    for (l&) in lines.items() {
        var colors: std::vec<u8> = {};
        for (i) in 0..l.len {
            colors.push(FG);
        }
        if (lang == "volt") {
            volt_line(*l, &c, &colors);
        } else if (lang == "sh" || lang == "bash" || lang == "shell") {
            sh_line(*l, &c, &colors);
        } else if (lang == "toml") {
            toml_line(*l, &colors);
        } else if (lang == "text" || lang == "txt" || lang == "plaintext") {
            for (i) in 0..l.len {
                *colors.at(i) = PLAIN;
            }
        } else {
            other_line(lang, *l, &c, &colors);
        }
        ls.add(line_value(*l, &colors));
    }
    d.set("lines", move ls);
    // the copy button's text: the lines joined by DEL
    var code: std::string = {};
    for (l&, i) in lines.items() {
        if (i > 0) {
            code.append("\x7f");
        }
        code.append(untab(*l).as_str());
    }
    d.set("code", std::json::string(code.as_str()));
    fill(&th.code, &d, out);
}

// a comment that only names a file (// lib/main.volt, # bolt.toml): the name
fn file_title(l: str) -> str? {
    var t = l.trim();
    // /* name */ and <!-- name --> too
    val block = t.strip_prefix("/*");
    if (block) {
        val inner = block.strip_suffix("*/");
        if (inner) {
            return name_only(inner.trim());
        }
    }
    val markers: str[3] = { "//", "#", "--" };
    for (m) in markers {
        val rest = t.strip_prefix(m);
        if (rest) {
            return name_only(rest.trim());
        }
    }
    return null;
}

// a file name (letters, digits, . / - _, with an extension), or null
fn name_only(name: str) -> str? {
    val dot = name.rfind(".") ?? return null;
    if (name.len == 0 || dot == 0 || dot + 1 >= name.len) {
        return null;
    }
    for (i) in 0..name.len {
        val c = name[i];
        if (!(word_char(c) || c == '.' || c == '/' || c == '-')) {
            return null;
        }
    }
    return name;
}

// one line: its runs of one colour; the indentation a run of its own (with the colour of the run
// it starts when that goes on past it)
fn line_value(l: str, colors: std::vec<u8>&) -> std::json::value {
    var x = std::json::object();
    x.set("empty", std::json::boolean(l.len == 0));
    var indent: usize = 0;
    while (indent < l.len && (l[indent] == ' ' || l[indent] == '\t')) {
        indent += 1;
    }
    var i: usize = 0;
    if (indent > 0 && indent < l.len) {
        var run_end: usize = 0;
        while (run_end < l.len && *colors.at(run_end) == *colors.at(0)) {
            run_end += 1;
        }
        x.set("indent", std::json::string(l[0..indent]));
        if (run_end > indent) {
            x.set("indent_style", std::json::string(STYLES[*colors.at(0)]));
        }
        i = indent;
    }
    var runs = std::json::array();
    while (i < l.len) {
        var j = i;
        while (j < l.len && *colors.at(j) == *colors.at(i)) {
            j += 1;
        }
        var r = std::json::object();
        r.set("style", std::json::string(STYLES[*colors.at(i)]));
        r.set("text", std::json::string(untab(l[i..j]).as_str()));
        runs.add(move r);
        i = j;
    }
    x.set("runs", move runs);
    return x;
}

// code's text as shown: a tab as two spaces
fn untab(s: str) -> std::string {
    var out: std::string = {};
    for (c) in s {
        if (c == '\t') {
            out.append("  ");
        } else {
            out.push(c);
        }
    }
    return out;
}

// characters, not bytes
fn utf8_len(s: str) -> usize {
    var n: usize = 0;
    for (i) in 0..s.len {
        if ((s[i] & 0xC0) != 0x80) {
            n += 1;
        }
    }
    return n;
}

// ---------- character classes ----------

fn word_char(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

fn ident_start(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

fn digit(c: u8) -> bool {
    return c >= '0' && c <= '9';
}

fn space(c: u8) -> bool {
    return c == ' ' || c == '\t';
}

// a word boundary before l[p] (regex \b), where l[p] is a word character
fn boundary(l: str, p: usize) -> bool {
    return p == 0 || !word_char(l[p - 1]);
}

// the identifier at l[p], if one starts there: its end
fn ident_at(l: str, p: usize) -> usize? {
    if (p >= l.len || !ident_start(l[p])) {
        return null;
    }
    var e = p + 1;
    while (e < l.len && word_char(l[e])) {
        e += 1;
    }
    return e;
}

// a path a::b::c at l[p]: its end
fn path_at(l: str, p: usize) -> usize? {
    var e = ident_at(l, p) ?? return null;
    while (e + 2 < l.len && l[e] == ':' && l[e + 1] == ':' && ident_start(l[e + 2])) {
        e = ident_at(l, e + 2) ?? e;
    }
    return e;
}

fn skip_spaces(l: str, p: usize) -> usize {
    var e = p;
    while (e < l.len && space(l[e])) {
        e += 1;
    }
    return e;
}

// is the whole word at l[p..] one of words, with a boundary after it
fn word_in(l: str, p: usize, words: str[..]) -> usize? {
    val e = ident_at(l, p) ?? return null;
    val w = l[p..e];
    for (x) in words {
        if (x == w) {
            return e;
        }
    }
    return null;
}

fn either_u8(c: bool, a: u8, b: u8) -> u8 {
    if (c) {
        return a;
    }
    return b;
}

fn paint(colors: std::vec<u8>&, from: usize, to: usize, c: u8) -> void {
    for (i) in from..to {
        *colors.at(i) = c;
    }
}

// ---------- Volt ----------

val PRIMS: str[23] = { "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f16", "f32", "f64", "f128", "bool", "str", "cstr", "void", "never", "type", "" };
val CONTROL: str[18] = { "if", "else", "for", "in", "while", "loop", "break", "continue", "return", "match", "default", "try", "catch", "defer", "errdefer", "await", "suspend", "resume" };
val STORAGE: str[7] = { "val", "var", "struct", "enum", "error", "trait", "namespace" };
val MODIFIERS: str[7] = { "public", "internal", "static", "extern", "export", "comptime", "async" };
val OTHER_KW: str[5] = { "use", "as", "attach", "move", "copy" };
val CONSTS: str[3] = { "true", "false", "null" };

// (?!prim\b): not a primitive type's name at l[p]
fn not_prim(l: str, p: usize) -> bool {
    return word_in(l, p, PRIMS[0..22]) == null;
}

fn volt_line(l: str, c: carry&, colors: std::vec<u8>&) -> void {
    var p: usize = 0;
    // what was left open on the line before
    if (c.comment) {
        val end = l.find("*/");
        if (end) {
            paint(colors, 0, end + 2, COM);
            p = end + 2;
            c.comment = false;
        } else {
            paint(colors, 0, l.len, COM);
            return;
        }
    } else if (c.triple || c.raw_triple) {
        val end = triple_end(l, 0, c.triple);
        if (end) {
            paint(colors, 0, end, STR);
            p = end;
            c.triple = false;
            c.raw_triple = false;
        } else {
            paint(colors, 0, l.len, STR);
            return;
        }
    } else if (c.quoted) {
        val end = quote_end(l, 0);
        if (end) {
            paint(colors, 0, end, STR);
            p = end;
            c.quoted = false;
        } else {
            paint(colors, 0, l.len, STR);
            return;
        }
    }
    while (p < l.len) {
        p = volt_at(l, p, c, colors);
    }
}

// where a """ string's closing quotes end, from l[p]; escapes count in a """ (not in an r""")
fn triple_end(l: str, p: usize, escapes: bool) -> usize? {
    var i = p;
    while (i < l.len) {
        if (escapes && l[i] == '\\') {
            i += 2;
            continue;
        }
        if (l[i..l.len].starts_with("\"\"\"")) {
            return i + 3;
        }
        i += 1;
    }
    return null;
}

// where a "..." string's closing quote ends, from l[p]
fn quote_end(l: str, p: usize) -> usize? {
    var i = p;
    while (i < l.len) {
        if (l[i] == '\\') {
            i += 2;
            continue;
        }
        if (l[i] == '"') {
            return i + 1;
        }
        i += 1;
    }
    return null;
}

// the first of the grammar's patterns that matches at l[p], painted; returns where to go on
fn volt_at(l: str, p: usize, c: carry&, colors: std::vec<u8>&) -> usize {
    val ch = l[p];
    val rest = l[p..l.len];
    // comments
    if (rest.starts_with("/*")) {
        val end = l[p + 2..l.len].find("*/");
        if (end) {
            paint(colors, p, p + 2 + end + 2, COM);
            return p + 2 + end + 2;
        }
        paint(colors, p, l.len, COM);
        c.comment = true;
        return l.len;
    }
    if (rest.starts_with("//")) {
        paint(colors, p, l.len, COM);
        return l.len;
    }
    // strings: r""", r", """, "
    val raw = ch == 'r' && boundary(l, p);
    if ((raw && rest.starts_with("r\"\"\"")) || rest.starts_with("\"\"\"")) {
        val open = p + 3 + @cast<usize>(raw);
        val end = triple_end(l, open, !raw);
        if (end) {
            paint(colors, p, end, STR);
            return end;
        }
        paint(colors, p, l.len, STR);
        c.triple = !raw;
        c.raw_triple = raw;
        return l.len;
    }
    if (raw && rest.starts_with("r\"")) {
        val end = l[p + 2..l.len].find("\"");
        val e = p + 2 + (end ?? (l.len - p - 2)) + 1;
        paint(colors, p, e, STR);
        return e;
    }
    if (ch == '"') {
        val end = quote_end(l, p + 1);
        if (end) {
            paint(colors, p, end, STR);
            return end;
        }
        paint(colors, p, l.len, STR);
        c.quoted = true;
        return l.len;
    }
    // chars: 'x' or an escape
    if (ch == '\'') {
        val end = char_end(l, p);
        if (end) {
            paint(colors, p, end, STR);
            return end;
        }
    }
    // builtins
    if (ch == '@' && p + 1 < l.len && ident_start(l[p + 1])) {
        val e = ident_at(l, p + 1) ?? (p + 1);
        paint(colors, p, e, FN);
        return e;
    }
    if (word_char(ch) && boundary(l, p)) {
        val e = volt_word(l, p, colors);
        if (e) {
            return e;
        }
    }
    // -> T (a type after the arrow, unless it's a primitive)
    if (rest.starts_with("->")) {
        val s = skip_spaces(l, p + 2);
        if (not_prim(l, s)) {
            val e = path_at(l, s);
            if (e) {
                paint(colors, p, p + 2, KW);
                paint(colors, s, e, TY);
                return e;
            }
        }
    }
    // a generic parameter line: <T: type, N: usize>
    if (ch == '<' && l[0..p].trim().len == 0 && generic_line(l, p)) {
        return generic_params(l, p, colors);
    }
    // numbers
    if (digit(ch) && boundary(l, p)) {
        val e = number_end(l, p);
        if (e) {
            paint(colors, p, e, NUM);
            return e;
        }
    }
    // operators
    if (rest.starts_with("::")) {
        return p + 2;
    }
    val op = operator_len(rest);
    if (op > 0) {
        paint(colors, p, p + op, KW);
        return p + op;
    }
    return p + 1;
}

// the patterns that start with a word, in the grammar's order; null when none matches here
fn volt_word(l: str, p: usize, colors: std::vec<u8>&) -> usize? {
    val e = ident_at(l, p) ?? return null;
    val w = l[p..e];
    val after = skip_spaces(l, e);
    // declarations: fn NAME, struct NAME (enum, error, trait), type NAME =, namespace PATH
    if (after > e) {
        if (w == "fn") {
            val n = ident_at(l, after);
            if (n) {
                paint(colors, p, e, KW);
                paint(colors, after, n, FN);
                return n;
            }
        }
        if (w == "struct" || w == "enum" || w == "error" || w == "trait") {
            val n = ident_at(l, after);
            if (n) {
                paint(colors, p, e, KW);
                paint(colors, after, n, TY);
                return n;
            }
        }
        if (w == "type") {
            val n = ident_at(l, after);
            if (n != null && l[skip_spaces(l, n ?? 0)..l.len].starts_with("=")) {
                paint(colors, p, e, KW);
                paint(colors, after, n ?? 0, TY);
                return n;
            }
        }
        if (w == "namespace") {
            val n = path_at(l, after);
            if (n) {
                paint(colors, p, e, KW);
                return n;
            }
        }
        // val x: T
        if (w == "val" || w == "var") {
            val n = ident_at(l, after);
            if (n) {
                val colon = skip_spaces(l, n);
                if (colon < l.len && l[colon] == ':' && !(colon + 1 < l.len && l[colon + 1] == ':')) {
                    val s = skip_spaces(l, colon + 1);
                    if (not_prim(l, s)) {
                        val t = path_at(l, s);
                        if (t) {
                            paint(colors, p, e, KW);
                            paint(colors, s, t, TY);
                            return t;
                        }
                    }
                }
            }
        }
        // attach Trait<..> -> T
        if (w == "attach" && (ident_at(l, after) == null || l[after..(ident_at(l, after) ?? after)] != "fn")) {
            var q = after;
            var trait_end: usize? = null;
            val tp = path_at(l, q);
            if (tp) {
                trait_end = tp;
                q = skip_spaces(l, tp);
                if (q < l.len && l[q] == '<') {
                    val gt = l[q..l.len].find(">");
                    if (gt) {
                        q = skip_spaces(l, q + gt + 1);
                    }
                }
            }
            if (l[q..l.len].starts_with("->")) {
                val s = skip_spaces(l, q + 2);
                if (not_prim(l, s)) {
                    val t = path_at(l, s);
                    if (t) {
                        paint(colors, p, e, KW);
                        if (trait_end) {
                            paint(colors, after, trait_end, TY);
                        }
                        paint(colors, q, q + 2, KW);
                        paint(colors, s, t, TY);
                        return t;
                    }
                }
            }
        }
    }
    // NAME<args> (not a call): a type
    if (l[e..l.len].starts_with("<")) {
        val close = generic_args_end(l, e);
        if (close) {
            val past = skip_spaces(l, close);
            if (!(past < l.len && l[past] == '(')) {
                paint(colors, p, e, TY);
                return e;
            }
        }
    }
    // test "name" { }: a test block
    if (w == "test" && after > e && after < l.len && l[after] == '"') {
        paint(colors, p, e, KW);
        return e;
    }
    // attach operator +(...)
    if (w == "operator" && after < l.len && "+-*/%&|^~<>=![".find(l[after..after + 1]) != null) {
        paint(colors, p, e, KW);
        return e;
    }
    // keywords, types, constants
    if (word_in(l, p, CONTROL) != null || w == "fn" || word_in(l, p, STORAGE) != null || word_in(l, p, MODIFIERS) != null || word_in(l, p, OTHER_KW) != null) {
        paint(colors, p, e, KW);
        return e;
    }
    if (w == "this") {
        return e;
    }
    if (word_in(l, p, PRIMS[0..22]) != null) {
        paint(colors, p, e, TY);
        return e;
    }
    if (word_in(l, p, CONSTS) != null) {
        paint(colors, p, e, NUM);
        return e;
    }
    // a constant's CAPS name is plain
    if (caps(w)) {
        return e;
    }
    // numbers are words too: 0x1F, 1_000
    if (digit(l[p])) {
        return null;
    }
    // a call: NAME (
    if (after < l.len && l[after] == '(') {
        paint(colors, p, e, FN);
        return after;
    }
    // a::b: the path's names are plain
    return e;
}

// [A-Z][A-Z0-9_]+
fn caps(w: str) -> bool {
    if (w.len < 2 || !(w[0] >= 'A' && w[0] <= 'Z')) {
        return false;
    }
    for (i) in 1..w.len {
        if (!((w[i] >= 'A' && w[i] <= 'Z') || digit(w[i]) || w[i] == '_')) {
            return false;
        }
    }
    return true;
}

// <A, B> right after a name, of the characters a type's arguments use: where it ends
fn generic_args_end(l: str, p: usize) -> usize? {
    var i = p + 1;
    var arg = false;
    while (i < l.len) {
        val c = l[i];
        if (word_char(c) || c == ':' || c == '&' || c == '*' || c == '[' || c == ']' || c == '.' || c == '?') {
            arg = true;
            i += 1;
        } else if (c == ',' && arg) {
            i += 1;
            if (i < l.len && l[i] == ' ') {
                i += 1;
            }
            arg = false;
        } else if (c == '>' && arg) {
            return i + 1;
        } else {
            return null;
        }
    }
    return null;
}

// does the line, from its < at p, hold only template parameters: [^<>]* with nested <..> and a
// closing > at the end
fn generic_line(l: str, p: usize) -> bool {
    var depth = 0;
    for (i) in p..l.len {
        if (l[i] == '<') {
            depth += 1;
            if (depth > 2) {
                return false;
            }
        } else if (l[i] == '>') {
            depth -= 1;
            if (depth == 0) {
                return l[i + 1..l.len].trim().len == 0;
            }
        }
    }
    return false;
}

// a template parameter line: names before : are types, then types, numbers, strings and paths
fn generic_params(l: str, p: usize, colors: std::vec<u8>&) -> usize {
    val close = l.rfind(">") ?? (l.len - 1);
    var i = p + 1;
    while (i < close) {
        val ch = l[i];
        if (ch == '"') {
            val end = quote_end(l, i + 1) ?? close;
            paint(colors, i, end, STR);
            i = end;
            continue;
        }
        if (digit(ch) && boundary(l, i)) {
            val e = number_end(l, i) ?? (i + 1);
            paint(colors, i, e, NUM);
            i = e;
            continue;
        }
        if (ident_start(ch) && boundary(l, i)) {
            val e = ident_at(l, i) ?? (i + 1);
            // NAME... :  or NAME :
            var after = e;
            if (l[after..l.len].starts_with("...")) {
                after += 3;
            }
            if (l[skip_spaces(l, after)..l.len].starts_with(":")) {
                paint(colors, i, e, TY);
                paint(colors, e, after, KW);
                i = after;
                continue;
            }
            val pe = path_at(l, i) ?? e;
            paint(colors, i, pe, TY);
            i = pe;
            continue;
        }
        i += 1;
    }
    return l.len;
}

// a number at l[p]: hex, binary, octal, float, integer; where it ends (\b after it)
fn number_end(l: str, p: usize) -> usize? {
    var e = p;
    if (l[p..l.len].starts_with("0x") || l[p..l.len].starts_with("0b") || l[p..l.len].starts_with("0o")) {
        e = p + 2;
        while (e < l.len && (word_char(l[e]))) {
            e += 1;
        }
        return e;
    }
    while (e < l.len && (digit(l[e]) || l[e] == '_')) {
        e += 1;
    }
    // .digits, then an exponent
    if (e + 1 < l.len && l[e] == '.' && digit(l[e + 1])) {
        e += 1;
        while (e < l.len && (digit(l[e]) || l[e] == '_')) {
            e += 1;
        }
        e = exponent(l, e);
    } else {
        e = exponent(l, e);
    }
    if (e < l.len && word_char(l[e])) {
        return null; // 1st, 2x: not a number
    }
    return e;
}

fn exponent(l: str, p: usize) -> usize {
    if (p < l.len && (l[p] == 'e' || l[p] == 'E')) {
        var e = p + 1;
        if (e < l.len && (l[e] == '+' || l[e] == '-')) {
            e += 1;
        }
        if (e < l.len && digit(l[e])) {
            while (e < l.len && digit(l[e])) {
                e += 1;
            }
            return e;
        }
    }
    return p;
}

// a char literal at l[p] ('x', '\n', '\x41', '\u{1F600}', or one UTF-8 character): where it ends
fn char_end(l: str, p: usize) -> usize? {
    var i = p + 1;
    if (i >= l.len) {
        return null;
    }
    if (l[i] == '\\') {
        i += 1;
        if (i >= l.len) {
            return null;
        }
        if (l[i] == 'x') {
            i += 3;
        } else if (l[i] == 'u') {
            val close = l[i..l.len].find("}") ?? return null;
            i += close + 1;
        } else {
            i += 1;
        }
    } else if (l[i] == '\'') {
        return null;
    } else {
        var n: usize = 1;
        if (l[i] >= 0xF0) {
            n = 4;
        } else if (l[i] >= 0xE0) {
            n = 3;
        } else if (l[i] >= 0xC0) {
            n = 2;
        }
        i += n;
    }
    if (i < l.len && l[i] == '\'') {
        return i + 1;
    }
    return null;
}

// the grammar's operator alternatives, longest first as it lists them
fn operator_len(s: str) -> usize {
    val ops: str[24] = { "->", "=>", "??", "...", "..=", "..", "<<=", ">>=", "+%=", "-%=", "*%=", "+%", "-%", "*%", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "++", "--" };
    for (o) in ops {
        if (s.starts_with(o)) {
            return o.len;
        }
    }
    // [+\-*/%&|^]=
    if (s.len >= 2 && s[1] == '=' && "+-*/%&|^".contains(s[0..1])) {
        return 2;
    }
    if ("+-*/%&|^~!<>=?".contains(s[0..1])) {
        return 1;
    }
    return 0;
}

// ---------- sh ----------

// a command's first word is a function, its arguments strings (numbers as numbers); # comments;
// && | ; and $( start a command; $NAME is plain; a line after one ending in \ goes on with its command
fn sh_line(l: str, c: carry&, colors: std::vec<u8>&) -> void {
    var p: usize = 0;
    var command = !c.continued;
    c.continued = l.trim_end().ends_with("\\");
    while (p < l.len) {
        val ch = l[p];
        if (space(ch)) {
            p += 1;
            continue;
        }
        if (ch == '#' && (p == 0 || space(l[p - 1]))) {
            paint(colors, p, l.len, COM);
            return;
        }
        if (l[p..l.len].starts_with("&&") || l[p..l.len].starts_with("||")) {
            p += 2;
            command = true;
            continue;
        }
        if (ch == '|' || ch == ';') {
            p += 1;
            command = true;
            continue;
        }
        if (ch == '>' || ch == '<') {
            var e = p + 1;
            if (e < l.len && l[e] == ch) {
                e += 1;
            }
            paint(colors, p, e, KW);
            p = e;
            continue;
        }
        // a word: up to a space (quotes keep spaces in)
        var e = p;
        while (e < l.len && !space(l[e])) {
            if (l[e] == '"' || l[e] == '\'') {
                val q = l[e];
                e += 1;
                while (e < l.len && l[e] != q) {
                    e += 1;
                }
            }
            if (e < l.len) {
                e += 1;
            }
        }
        // VAR=value before the command
        val eq = l[p..e].find("=");
        if (command && eq != null && (ident_at(l, p) ?? 0) == p + (eq ?? 0)) {
            paint(colors, p + (eq ?? 0), p + (eq ?? 0) + 1, KW);
            paint(colors, p + (eq ?? 0) + 1, e, STR);
        } else if (command && ch == '.' && e > p + 1) {
            // ./x, ../x: Shiki's shell grammar reads the dot as the source builtin
            paint(colors, p, p + 1, FN);
            paint(colors, p + 1, e, STR);
            command = false;
        } else if (command) {
            paint(colors, p, e, FN);
            command = false;
        } else if (all_digits(l[p..e])) {
            paint(colors, p, e, NUM);
        } else {
            paint(colors, p, e, STR);
        }
        expansions(l, p, e, colors);
        p = e;
    }
}

fn all_digits(w: str) -> bool {
    for (i) in 0..w.len {
        if (!digit(w[i])) {
            return false;
        }
    }
    return w.len > 0;
}

// inside a word: $NAME plain (not in '...' or after \), $(cmd starts a command
fn expansions(l: str, from: usize, to: usize, colors: std::vec<u8>&) -> void {
    var single = false;
    var i = from;
    while (i < to) {
        val ch = l[i];
        if (ch == '\'') {
            single = !single;
        } else if (ch == '\\') {
            i += 2;
            continue;
        } else if (ch == '$' && !single && i + 1 < to) {
            if (l[i + 1] == '(') {
                val e = ident_at(l, i + 2);
                if (e) {
                    paint(colors, i + 2, e, FN);
                    i = e;
                    continue;
                }
            } else if (ident_start(l[i + 1])) {
                val e = ident_at(l, i + 1) ?? (i + 1);
                paint(colors, i, e, FG);
                i = e;
                continue;
            }
        }
        i += 1;
    }
}

// ---------- toml ----------

fn toml_line(l: str, colors: std::vec<u8>&) -> void {
    var p: usize = 0;
    while (p < l.len) {
        val ch = l[p];
        if (ch == '#') {
            paint(colors, p, l.len, COM);
            return;
        }
        if (ch == '"' || ch == '\'') {
            var e = p + 1;
            while (e < l.len && l[e] != ch) {
                if (l[e] == '\\') {
                    e += 1;
                }
                e += 1;
            }
            e = e + 1;
            if (e > l.len) {
                e = l.len;
            }
            paint(colors, p, e, STR);
            p = e;
            continue;
        }
        // values: numbers and booleans after =
        if (word_char(ch) && boundary(l, p) && l[0..p].contains("=")) {
            var e = p;
            while (e < l.len && (word_char(l[e]) || l[e] == '.' || l[e] == '-')) {
                e += 1;
            }
            val w = l[p..e];
            if (w == "true" || w == "false" || digit(w[0])) {
                paint(colors, p, e, NUM);
            }
            p = e;
            continue;
        }
        p += 1;
    }
}

// ---------- the others ----------

// keywords, types, strings, numbers, comments and calls, by the language's own lists
fn other_line(lang: str, l: str, c: carry&, colors: std::vec<u8>&) -> void {
    if (lang == "xml" || lang == "html") {
        markup_line(l, colors);
        return;
    }
    if (lang == "elisp" || lang == "lisp" || lang == "scheme") {
        lisp_line(l, colors);
        return;
    }
    if (lang == "llvm") {
        llvm_line(l, colors);
        return;
    }
    val hash = lang == "python" || lang == "ruby" || lang == "yaml";
    val dash = lang == "lua";
    var p: usize = 0;
    var decl = false; // the word after struct, class, ...: a type's name
    if (c.comment) {
        val end = l.find("*/");
        if (end) {
            p = end + 2;
            paint(colors, 0, p, COM);
            c.comment = false;
        } else {
            paint(colors, 0, l.len, COM);
            return;
        }
    }
    while (p < l.len) {
        val ch = l[p];
        val rest = l[p..l.len];
        if ((hash && ch == '#') || (dash && rest.starts_with("--")) || (!hash && !dash && rest.starts_with("//"))) {
            paint(colors, p, l.len, COM);
            return;
        }
        if (!hash && !dash && rest.starts_with("/*")) {
            val end = l[p + 2..l.len].find("*/");
            if (end) {
                val e = p + 2 + end + 2;
                paint(colors, p, e, COM);
                p = e;
                continue;
            }
            paint(colors, p, l.len, COM);
            c.comment = true;
            return;
        }
        if (ch == '"' || (ch == '\'' && lang != "rust")) {
            var e = p + 1;
            while (e < l.len && l[e] != ch) {
                if (l[e] == '\\') {
                    e += 1;
                }
                e += 1;
            }
            e += 1;
            if (e > l.len) {
                e = l.len;
            }
            // a JSON object's key is a name
            val key = lang == "json" && l[skip_spaces(l, e)..l.len].starts_with(":");
            paint(colors, p, e, either_u8(key, TY, STR));
            p = e;
            continue;
        }
        if (digit(ch) && boundary(l, p)) {
            val e = number_end(l, p) ?? (p + 1);
            paint(colors, p, e, NUM);
            p = e;
            continue;
        }
        if (ident_start(ch) && boundary(l, p)) {
            val e = ident_at(l, p) ?? (p + 1);
            val w = l[p..e];
            val after = skip_spaces(l, e);
            if (decl) {
                paint(colors, p, e, TY);
                decl = false;
            } else if (is_keyword(lang, w)) {
                paint(colors, p, e, KW);
                // C's grammar leaves a struct's name plain
                decl = lang != "c" && (w == "struct" || w == "class" || w == "enum" || w == "union" || w == "interface" || w == "trait" || w == "impl");
            } else if (is_type(lang, w)) {
                paint(colors, p, e, either_u8(primitive_keywords(lang), KW, TY));
            } else if (w == "true" || w == "false" || w == "null" || w == "nil" || w == "None" || w == "True" || w == "False") {
                paint(colors, p, e, NUM);
            } else if (after < l.len && l[after] == '(') {
                paint(colors, p, e, FN);
            }
            p = e;
            continue;
        }
        if (lang == "go" && rest.starts_with(":=")) {
            paint(colors, p, p + 2, KW);
            p += 2;
            continue;
        }
        val op = operator_len(rest);
        if (op > 0 && ch != '<' && ch != '>') {
            paint(colors, p, p + op, KW);
            p += op;
            continue;
        }
        p += 1;
    }
}

// Shiki's grammars for these colour int, double and the like as keywords
fn primitive_keywords(lang: str) -> bool {
    return lang == "c" || lang == "cpp" || lang == "zig" || lang == "csharp";
}

// LLVM IR: instructions, types and attributes are keywords, %values plain, @functions named,
// numbers and labels numbers, ; comments
fn llvm_line(l: str, colors: std::vec<u8>&) -> void {
    val words: str[] = {
        "define", "declare", "internal", "private", "external", "dso_local", "unnamed_addr", "constant",
        "global", "alloca", "load", "store", "getelementptr", "inbounds", "nuw", "nsw", "align", "br",
        "label", "ret", "call", "tail", "fmul", "fadd", "fsub", "fdiv", "mul", "add", "sub", "sdiv", "udiv",
        "icmp", "fcmp", "phi", "select", "zext", "sext", "trunc", "bitcast", "to", "x", "double", "float",
        "void", "i1", "i8", "i16", "i32", "i64", "i128", "half", "eq", "ne", "slt", "sgt", "sle", "sge",
        "switch", "unreachable", "noundef", "nonnull", "zeroinitializer", "undef", "poison", "true", "false",
    };
    var p: usize = 0;
    while (p < l.len) {
        val ch = l[p];
        if (ch == ';') {
            paint(colors, p, l.len, COM);
            return;
        }
        if (ch == '%' || ch == '@') {
            var e = p + 1;
            while (e < l.len && (word_char(l[e]) || l[e] == '.')) {
                e += 1;
            }
            if (ch == '@' && e < l.len && l[e] == '(') {
                paint(colors, p, e, FN);
            }
            p = e;
            continue;
        }
        if (digit(ch) && boundary(l, p)) {
            var e = p;
            while (e < l.len && (digit(l[e]) || l[e] == '.')) {
                e += 1;
            }
            paint(colors, p, e, NUM);
            p = e;
            continue;
        }
        if (ident_start(ch) && boundary(l, p)) {
            val e = ident_at(l, p) ?? (p + 1);
            val w = l[p..e];
            for (k) in words {
                if (k == w) {
                    paint(colors, p, e, KW);
                }
            }
            p = e;
            continue;
        }
        p += 1;
    }
}

// markup: only attribute values are coloured
fn markup_line(l: str, colors: std::vec<u8>&) -> void {
    var tag = false;
    var p: usize = 0;
    while (p < l.len) {
        val ch = l[p];
        if (ch == '<') {
            tag = true;
        } else if (ch == '>') {
            tag = false;
        } else if (ch == '"' && tag) {
            val end = l[p + 1..l.len].find("\"") ?? (l.len - p - 2);
            paint(colors, p, p + end + 2, STR);
            p += end + 2;
            continue;
        }
        p += 1;
    }
}

// lisp: the name after ( is a function, strings are strings
fn lisp_line(l: str, colors: std::vec<u8>&) -> void {
    var p: usize = 0;
    while (p < l.len) {
        val ch = l[p];
        if (ch == ';') {
            paint(colors, p, l.len, COM);
            return;
        }
        if (ch == '"') {
            var e = p + 1;
            while (e < l.len && l[e] != '"') {
                if (l[e] == '\\') {
                    e += 1;
                }
                e += 1;
            }
            e += 1;
            paint(colors, p, e, STR);
            p = e;
            continue;
        }
        if (ch == '(' && p + 1 < l.len && ident_start(l[p + 1])) {
            var e = p + 1;
            while (e < l.len && (word_char(l[e]) || l[e] == '-')) {
                e += 1;
            }
            paint(colors, p + 1, e, FN);
            p = e;
            continue;
        }
        if (ch == '.' && p > 0 && space(l[p - 1]) && p + 1 < l.len && space(l[p + 1])) {
            paint(colors, p, p + 1, KW);
        }
        p += 1;
    }
}

fn is_keyword(lang: str, w: str) -> bool {
    val common: str[] = {
        "if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "do",
        "struct", "enum", "union", "class", "const", "static", "extern", "public", "private", "protected",
        "import", "export", "from", "fn", "func", "def", "let", "var", "mut", "pub", "mod", "impl",
        "trait", "where", "match", "in", "as", "try", "catch", "throw", "namespace", "using",
        "typedef", "template", "typename", "package", "interface", "type", "defer", "async", "await",
        "yield", "lambda", "end", "then", "local", "function", "elif", "unless", "module", "require",
        "self", "this", "super", "and", "or", "not", "is", "with", "pass", "raise", "except", "finally",
        "override", "virtual", "inline", "sizeof", "typeof", "unsafe", "final", "on", "begin", "rescue",
        "val", "fun", "object", "when", "init", "guard", "let", "comptime",
    };
    for (k) in common {
        if (k == w) {
            return true;
        }
    }
    return false;
}

fn is_type(lang: str, w: str) -> bool {
    val types: str[] = {
        "int", "char", "float", "double", "long", "short", "unsigned", "signed", "bool", "size_t", "void",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t",
        "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
        "f64", "str", "String", "string", "Vec", "Option", "Result", "byte", "rune", "error", "object",
        "number", "boolean", "any", "Int", "Double", "Bool", "Float", "auto", "uint", "ulong",
    };
    for (t) in types {
        if (t == w) {
            return true;
        }
    }
    return false;
}
