// voltc doc NAME: package NAME's declarations as JSON, for the site's reference pages and other
// tools. Each carries its signature as written (on one line, without its @attributes) and its doc
// comment: the `//` lines directly above it (a blank line or a `// ----------` separator ends the
// block), or for a field or variant, the comment after it on its line. `internal` declarations are
// left out. Only the parser runs: the package doesn't have to type-check.

// `voltc doc NAME`: std (--std, $VOLT_STD, or next to voltc) or a package given with --pkg NAME=DIR
fn doc_cmd(c: cli&) -> i32 {
    val name = *c.files.at(0);
    var dir: std::string = {};
    if (name == "std") {
        dir = find_std(c) ?? die(S("there's no std to document (--no-std)"));
    }
    for (p&) in c.pkgs.items() {
        if (p.name == name) {
            dir = S(p.path);
        }
    }
    if (dir.len() == 0) {
        die(fmt("no package '{}' to document (std, or one given with --pkg)", S(name)));
    }
    var s: sources = {};
    for (f&) in volt_files(dir.as_str()).items() {
        add_file(&s, f.as_str(), null);
    }
    for (i) in 0..s.names.len {
        put(&s.files, { name: s.names.at(i).as_str(), text: s.texts.at(i).as_str() });
    }
    val bad = parse_sources(&s);
    if (bad.len > 0) {
        report_diags(c, &s.files, &bad);
        return 1;
    }
    var files = std::json::array();
    var items = std::json::array();
    var w: doc_writer = { text: "", file: "", items: &items };
    for (i) in 0..s.files.len {
        w.text = s.files.at(i).text;
        w.file = s.files.at(i).name[dir.len() + 1..s.files.at(i).name.len];
        var f = std::json::object();
        f.set("file", std::json::string(w.file));
        f.set("doc", std::json::string(file_doc(w.text).as_str()));
        files.add(move f);
        var ns: std::vec<str> = {};
        w.walk(s.asts.at(i), &ns);
    }
    var out = std::json::object();
    out.set("package", std::json::string(name));
    out.set("files", move files);
    out.set("items", move items);
    std::println("{}", out.text());
    return 0;
}

struct doc_writer {
    text: str; // the file being read
    file: str; // its name in the package directory
    items: std::json::value&; // what it found
}

// document items, declared in namespace ns (a path inside the package)
attach fn walk(this: doc_writer&, items: std::vec<item>&, ns: std::vec<str>&) -> void {
    for (it&) in items.items() {
        if (it.vis == vis::INTERNAL) {
            continue;
        }
        match (it.kind) {
            .FN(f&) => {
                if (f.is_attach) {
                    var o = this.entry("method", f.name, ns, it.span);
                    o.set("receiver", std::json::string(this.receiver(f)));
                    this.finish(move o, this.fn_text(it, f), it.span);
                } else {
                    val o = this.entry("fn", f.name, ns, it.span);
                    this.finish(move o, this.fn_text(it, f), it.span);
                }
            },
            .STRUCT(s&) => {
                var o = this.entry("struct", s.name, ns, it.span);
                var fields = std::json::array();
                for (f&) in s.fields.items() {
                    fields.add(this.member(f.name, f.span));
                }
                o.set("fields", move fields);
                this.finish(move o, this.head_text(it.span, s.name), it.span);
            },
            .ENUM(e&) => {
                var kind = "enum";
                if (e.is_error) {
                    kind = "error";
                }
                var o = this.entry(kind, e.name, ns, it.span);
                var variants = std::json::array();
                for (v&) in e.variants.items() {
                    variants.add(this.member(v.name, v.span));
                }
                o.set("variants", move variants);
                this.finish(move o, this.head_text(it.span, e.name), it.span);
            },
            .TRAIT(n, fs&) => {
                var o = this.entry("trait", n, ns, it.span);
                var methods = std::json::array();
                for (m&) in fs.items() {
                    match (m.kind) {
                        .FN(f&) => {
                            var x = std::json::object();
                            x.set("name", std::json::string(f.name));
                            x.set("signature", std::json::string(this.fn_text(m, f).as_str()));
                            x.set("doc", std::json::string(doc_above(this.text, @cast<usize>(m.span.lo)).as_str()));
                            methods.add(move x);
                        },
                        default => {},
                    }
                }
                o.set("methods", move methods);
                this.finish(move o, this.head_text(it.span, n), it.span);
            },
            .ATTACH(tr&, tg&, fs) => {
                // a trait implemented for a type (its fns are documented on the trait)
                var o = this.entry("impl", this.type_name(tg.span), ns, it.span);
                o.set("trait", std::json::string(this.type_name(tr.span)));
                this.finish(move o, this.head_text(it.span, "attach"), it.span);
            },
            .NAMESPACE(path&, xs&) => {
                var inner = copy *ns;
                for (p) in path.items() {
                    put(&inner, p);
                }
                this.walk(xs, &inner);
            },
            .GLOBAL(l&) => {
                match (l.pat.kind) {
                    .BIND(n) => {
                        val o = this.entry("global", n, ns, it.span);
                        this.finish(move o, decl_text(this.text, @cast<usize>(it.span.lo), @cast<usize>(it.span.hi)), it.span);
                    },
                    default => {},
                }
            },
            default => {},
        }
    }
}

// a new entry: its kind, name and namespace
attach fn entry(this: doc_writer&, kind: str, name: str, ns: std::vec<str>&, span: span) -> std::json::value {
    var o = std::json::object();
    o.set("kind", std::json::string(kind));
    o.set("name", std::json::string(name));
    var path = std::json::array();
    for (p) in ns.items() {
        path.add(std::json::string(p));
    }
    o.set("namespace", move path);
    return move o;
}

// add the signature, doc comment and place to entry o, and o to the items
attach fn finish(this: doc_writer&, o0: std::json::value, signature: std::string, span: span) -> void {
    var o = move o0;
    o.set("signature", std::json::string(signature.as_str()));
    o.set("doc", std::json::string(doc_above(this.text, @cast<usize>(span.lo)).as_str()));
    o.set("file", std::json::string(this.file));
    o.set("line", std::json::number(@cast<f64>(line_of(this.text, @cast<usize>(span.lo)))));
    this.items.add(move o);
}

// a field or variant: its name, its text and its comment (after it on its line, or above it)
attach fn member(this: doc_writer&, name: str, span: span) -> std::json::value {
    var o = std::json::object();
    o.set("name", std::json::string(name));
    o.set("signature", std::json::string(decl_text(this.text, @cast<usize>(span.lo), @cast<usize>(span.hi)).as_str()));
    var doc = doc_after(this.text, @cast<usize>(span.hi));
    if (doc.len() == 0) {
        doc = doc_above(this.text, @cast<usize>(span.lo));
    }
    o.set("doc", std::json::string(doc.as_str()));
    return move o;
}

// a fn's declaration, without its body
attach fn fn_text(this: doc_writer&, it: item&, f: fn_decl&) -> std::string {
    var hi = @cast<usize>(it.span.hi);
    if (f.body) {
        hi = @cast<usize>(f.body.span.lo);
    }
    return decl_text(this.text, @cast<usize>(it.span.lo), hi);
}

// a struct's, enum's or trait's declaration up to its `{` (or `;`); name is where to start looking
attach fn head_text(this: doc_writer&, s: span, name: str) -> std::string {
    val at = find_word(this.text, s, name, false) ?? s;
    var hi = @cast<usize>(at.hi);
    while (hi < @cast<usize>(s.hi) && this.text[hi] != '{' && this.text[hi] != ';') {
        hi += 1;
    }
    return decl_text(this.text, @cast<usize>(s.lo), hi);
}

// the type an attached fn takes as this: `this: std::vec<T, A>&` is vec's
attach fn receiver(this: doc_writer&, f: fn_decl&) -> str {
    if (f.params.len == 0) {
        return "";
    }
    val p = f.params.at(0);
    if (p.name != "this" || p.ty == null) {
        return "";
    }
    return this.type_name(p.ty.value.span);
}

// a type's bare name: no namespace, generic arguments, &, * or ?
attach fn type_name(this: doc_writer&, s: span) -> str {
    val t = this.text[@cast<usize>(s.lo)..@cast<usize>(s.hi)];
    var end = t.len;
    for (i) in 0..t.len {
        if (t[i] == '<' || t[i] == '&' || t[i] == '*' || t[i] == '?' || t[i] == '[') {
            end = i;
            break;
        }
    }
    var start: usize = 0;
    for (i) in 0..end {
        if (t[i] == ':') {
            start = i + 1;
        }
    }
    return t[start..end];
}

// text[lo..hi] on one line: whitespace runs as one space, comments and @attributes(...) dropped, no
// trailing `;`
fn decl_text(text: str, lo: usize, hi: usize) -> std::string {
    var out: std::string = {};
    var space = false;
    var i = lo;
    while (i < hi) {
        val c = text[i];
        if (c == '/' && i + 1 < hi && text[i + 1] == '/') {
            while (i < hi && text[i] != '\n') {
                i += 1;
            }
            space = out.len() > 0;
            continue;
        }
        if (starts_with(text[i..hi], "@attributes(")) {
            var depth = 0;
            while (i < hi) {
                if (text[i] == '(') {
                    depth += 1;
                } else if (text[i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
                i += 1;
            }
            space = out.len() > 0;
            continue;
        }
        if (is_space(c)) {
            space = out.len() > 0;
        } else {
            if (space) {
                out.push(' ');
                space = false;
            }
            out.push(c);
        }
        i += 1;
    }
    while (out.len() > 0 && (out.as_str()[out.len() - 1] == ';' || out.as_str()[out.len() - 1] == ',')) {
        out.bytes.pop();
    }
    return move out;
}

// the comment block directly above the line holding offset at
fn doc_above(text: str, at: usize) -> std::string {
    var start = at;
    while (start > 0 && text[start - 1] != '\n') {
        start -= 1;
    }
    // the lines above, nearest first
    var lines: std::vec<str> = {};
    while (start > 0) {
        val end = start - 1; // the newline ending the line above
        var ls = end;
        while (ls > 0 && text[ls - 1] != '\n') {
            ls -= 1;
        }
        val line = trim(text[ls..end]);
        if (!starts_with(line, "//")) {
            break;
        }
        val body = comment_body(line);
        if (starts_with(body, "----------")) {
            break;
        }
        put(&lines, body);
        start = ls;
    }
    var out: std::string = {};
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        out.append(*lines.at(i));
        if (i > 0) {
            out.push('\n');
        }
    }
    return move out;
}

// the comment after offset at on its line, if there is one
fn doc_after(text: str, at: usize) -> std::string {
    var i = at;
    while (i + 1 < text.len && text[i] != '\n') {
        if (text[i] == '/' && text[i + 1] == '/') {
            var end = i;
            while (end < text.len && text[end] != '\n') {
                end += 1;
            }
            return S(comment_body(trim(text[i..end])));
        }
        i += 1;
    }
    return {};
}

// a file's leading comment block
fn file_doc(text: str) -> std::string {
    var out: std::string = {};
    var i: usize = 0;
    while (i < text.len) {
        var end = i;
        while (end < text.len && text[end] != '\n') {
            end += 1;
        }
        val line = trim(text[i..end]);
        if (!starts_with(line, "//")) {
            break;
        }
        if (out.len() > 0) {
            out.push('\n');
        }
        out.append(comment_body(line));
        i = end + 1;
    }
    return move out;
}

// `// text` → `text`
fn comment_body(line: str) -> str {
    var b = line[2..line.len];
    if (b.len > 0 && b[0] == ' ') {
        b = b[1..b.len];
    }
    return b;
}

// the 1-based line of offset at
fn line_of(text: str, at: usize) -> usize {
    var n: usize = 1;
    for (i) in 0..at {
        if (text[i] == '\n') {
            n += 1;
        }
    }
    return n;
}
