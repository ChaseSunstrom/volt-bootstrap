// std::html: text made safe for HTML (escaped), and templates rendered from JSON values.
// (Part of package std: the package loader wraps every file in `namespace std`.)
//
// A template is HTML with tags in it, parsed once and rendered as often as needed:
//   {{path}}                   the value at path, escaped (a string, a number, true or false)
//   {{{path}}}                 the value as it is (HTML made elsewhere)
//   {{for x in path}}...{{end}}  the body once per element of the array at path, as x
//   {{if path}}...{{else}}...{{end}}  the first part when the value is true, a non-empty string or
//                              array, or a number other than 0 (else is optional)
// A path is names joined by dots (page.title); its first name is a loop's variable or a member of
// the data. Text can't hold a {{ of its own: give it as a value. After an error, why() says which
// line and tag it came from.
//
// render(src, &data, &out) checks a template against data's type while compiling (see render).

namespace html {
    // why a template can't be parsed (SYNTAX), read from its file (READ) or rendered (MISSING: a
    // slot or a loop names a value the data doesn't have)
    public error template_error {
        SYNTAX,
        MISSING,
        READ,
    }

    // the last template error on this thread, explained (see why)
    @attributes([@thread_local])
    var why_text: u8[240];
    @attributes([@thread_local])
    var why_len: usize;

    // what the last template error on this thread was: its line, its tag and what's wrong with it
    // ("line 3: {{page.title}}: no value")
    public fn why() -> str {
        return @cast<str>(@slice(&why_text[0], why_len));
    }

    // e, with why() set to "WHERE: WHAT" (cut to fit)
    fn failed(e: template_error, where: str, what: str) -> template_error {
        val s = std::fmt::format("{}: {}", where, what);
        why_len = 0;
        for (c) in s.as_str() {
            if (why_len == why_text.len) {
                break;
            }
            why_text[why_len] = c;
            why_len += 1;
        }
        // cut where a character starts, not inside one
        while (why_len < s.len() && why_len > 0 && (s.as_str()[why_len] & 0xC0) == 0x80) {
            why_len -= 1;
        }
        return e;
    }

    // "line N: TAG" for src's tag from open to end
    fn where_of(src: str, open: usize, end: usize) -> std::string {
        return std::fmt::format("line {}: {}", src[0..open].count("\n") + 1, src[open..end]);
    }

    // s with &, <, >, " and ' as entities, after out's text (fine in text and in quoted attributes)
    public fn escape(s: str, out: std::string&) -> void {
        for (c) in s {
            if (c == '&') {
                out.append("&amp;");
            } else if (c == '<') {
                out.append("&lt;");
            } else if (c == '>') {
                out.append("&gt;");
            } else if (c == '"') {
                out.append("&quot;");
            } else if (c == '\'') {
                out.append("&#39;");
            } else {
                out.push(c);
            }
        }
    }

    // s escaped (see escape)
    public fn escaped(s: str) -> std::string {
        var out: std::string = {};
        escape(s, &out);
        return out;
    }

    // a parsed template (see the top of the file)
    public struct template {
        nodes: std::vec<node> = {};
    }

    enum node {
        TEXT: std::string,  // as it is
        SLOT: slot,         // {{path}}
        RAW: slot,          // {{{path}}}
        FOR: each,          // {{for name in path}}body{{end}}
        IF: branch,         // {{if path}}yes{{else}}no{{end}}
    }

    // a slot's path, and where it is ("line 3: {{page.title}}") for an error
    struct slot {
        path: std::string;
        at: std::string;
    }

    struct each {
        name: std::string;
        path: std::string;
        body: std::vec<node>;
        at: std::string;
    }

    struct branch {
        path: std::string;
        yes: std::vec<node>;
        no: std::vec<node>;
    }

    // a loop's variable while its body renders
    struct scope {
        name: str;
        v: std::json::value&;
    }

    // ---------- parsing ----------

    // the template in src
    public attach fn parse(static this: template, src: str) -> template_error!template {
        var t: template = {};
        var at: usize = 0;
        if (try parse_nodes(src, &at, &t.nodes) != 0) {
            // an {{end}} or {{else}} with nothing open (at is just past it)
            val open = src[0..at].rfind("{{") ?? 0;
            return failed(template_error::SYNTAX, where_of(src, open, at).as_str(), "nothing open for it");
        }
        return t;
    }

    // the template in file path
    public attach fn read(static this: template, path: str) -> template_error!template {
        val src = std::fs::read_file(path) catch |e| {
            return failed(template_error::READ, path, "can't be read");
        };
        return template::parse(src.as_str());
    }

    // nodes from src at at into out, up to the end (0), an {{end}} (1) or an {{else}} (2)
    fn parse_nodes(src: str, at: usize&, out: std::vec<node>&) -> template_error!u8 {
        while (*at < src.len) {
            val open = find_from(src, "{{", *at) ?? src.len;
            if (open > *at) {
                out.push(node::TEXT(std::string::from(src[*at..open]))) catch @panic("out of memory");
            }
            if (open == src.len) {
                *at = src.len;
                return 0;
            }
            if (open + 2 < src.len && src[open + 2] == '{') {
                // {{{path}}}
                val close = find_from(src, "}}}", open + 3) ?? return failed(template_error::SYNTAX, where_of(src, open, open + 3).as_str(), "no }}} after it");
                val w = where_of(src, open, close + 3);
                out.push(node::RAW({ path: try path_in(src[open + 3..close], w.as_str()), at: copy w })) catch @panic("out of memory");
                *at = close + 3;
                continue;
            }
            val close = find_from(src, "}}", open + 2) ?? return failed(template_error::SYNTAX, where_of(src, open, open + 2).as_str(), "no }} after it");
            val tag = src[open + 2..close].trim();
            val w = where_of(src, open, close + 2);
            *at = close + 2;
            if (tag == "end") {
                return 1;
            }
            if (tag == "else") {
                return 2;
            }
            if (tag.starts_with("for ")) {
                // for name in path
                val rest = tag[4..].trim();
                val sp = rest.find(" in ") ?? return failed(template_error::SYNTAX, w.as_str(), "a loop is {{for name in path}}");
                var l: each = { name: try path_in(rest[0..sp].trim(), w.as_str()), path: try path_in(rest[sp + 4..].trim(), w.as_str()), body: {}, at: copy w };
                if (l.name.as_str().find(".") != null) {
                    return failed(template_error::SYNTAX, w.as_str(), "a loop's name is one word");
                }
                if (try parse_nodes(src, at, &l.body) != 1) {
                    return failed(template_error::SYNTAX, w.as_str(), "no {{end}} for it");
                }
                out.push(node::FOR(move l)) catch @panic("out of memory");
                continue;
            }
            if (tag.starts_with("if ")) {
                var b: branch = { path: try path_in(tag[3..].trim(), w.as_str()), yes: {}, no: {} };
                val ended = try parse_nodes(src, at, &b.yes);
                if (ended == 2) {
                    if (try parse_nodes(src, at, &b.no) != 1) {
                        return failed(template_error::SYNTAX, w.as_str(), "no {{end}} for it (after one {{else}})");
                    }
                } else if (ended != 1) {
                    return failed(template_error::SYNTAX, w.as_str(), "no {{end}} for it");
                }
                out.push(node::IF(move b)) catch @panic("out of memory");
                continue;
            }
            out.push(node::SLOT({ path: try path_in(tag, w.as_str()), at: copy w })) catch @panic("out of memory");
        }
        return 0;
    }

    // path_of(s) for the tag at where
    fn path_in(s: str, where: str) -> template_error!std::string {
        return path_of(s) catch |e| {
            return failed(e, where, "not a path (names joined by dots)");
        };
    }

    // a path's text: names of letters, digits and _, joined by dots
    fn path_of(s: str) -> template_error!std::string {
        if (s.len == 0 || s == "if" || s == "for" || s == "end" || s == "else") {
            return template_error::SYNTAX;
        }
        var dot = true;
        for (c) in s {
            val word = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
            if (c == '.') {
                if (dot) {
                    return template_error::SYNTAX;
                }
                dot = true;
            } else if (word) {
                dot = false;
            } else {
                return template_error::SYNTAX;
            }
        }
        if (dot) {
            return template_error::SYNTAX;
        }
        return std::string::from(s);
    }

    // where needle is in s from from on
    fn find_from(s: str, needle: str, from: usize) -> usize? {
        val i = s[from..].find(needle) ?? return null;
        return from + i;
    }

    // ---------- rendering ----------

    // the template with data's values, after out's text
    public attach fn render(this: template&, data: std::json::value&, out: std::string&) -> template_error!void {
        var scopes: std::vec<scope> = {};
        try render_nodes(&this.nodes, data, &scopes, out);
    }

    fn render_nodes(nodes: std::vec<node>&, data: std::json::value&, scopes: std::vec<scope>&, out: std::string&) -> template_error!void {
        for (n&) in nodes.items() {
            match (*n) {
                .TEXT(s&) => { out.append(s.as_str()); },
                .SLOT(p&) => {
                    val v = lookup(p.path.as_str(), data, scopes);
                    put_value(v, true, out) catch |e| {
                        return failed(e, p.at.as_str(), "no value");
                    };
                },
                .RAW(p&) => {
                    val v = lookup(p.path.as_str(), data, scopes);
                    put_value(v, false, out) catch |e| {
                        return failed(e, p.at.as_str(), "no value");
                    };
                },
                .FOR(l&) => {
                    val xs = lookup(l.path.as_str(), data, scopes);
                    match (*xs) {
                        .ARR(items&) => {
                            for (x&) in items.items() {
                                scopes.push({ name: l.name.as_str(), v: x }) catch @panic("out of memory");
                                val r = render_nodes(&l.body, data, scopes, out);
                                scopes.pop();
                                try r;
                            }
                        },
                        default => { return failed(template_error::MISSING, l.at.as_str(), "no list"); },
                    }
                },
                .IF(b&) => {
                    if (truthy(lookup(b.path.as_str(), data, scopes))) {
                        try render_nodes(&b.yes, data, scopes, out);
                    } else {
                        try render_nodes(&b.no, data, scopes, out);
                    }
                },
            }
        }
    }

    // the value at path: its first name a loop's variable (the innermost of that name) or data's
    // member, the rest members of that (null when there's none)
    fn lookup(path: str, data: std::json::value&, scopes: std::vec<scope>&) -> std::json::value& {
        val dot = path.find(".") ?? path.len;
        val first = path[0..dot];
        var v = data.get(first);
        var k = scopes.len;
        while (k > 0) {
            k -= 1;
            if (scopes[k].name == first) {
                v = scopes[k].v;
                break;
            }
        }
        var at = dot;
        while (at < path.len) {
            val rest = path[at + 1..];
            val next = rest.find(".") ?? rest.len;
            v = v.get(rest[0..next]);
            at += 1 + next;
        }
        return v;
    }

    // a value in a slot: text escaped (or not), a number, true or false; null is MISSING
    fn put_value(v: std::json::value&, escape_it: bool, out: std::string&) -> template_error!void {
        match (*v) {
            .NULL => { return template_error::MISSING; },
            .STR(s&) => {
                if (escape_it) {
                    escape(s.as_str(), out);
                } else {
                    out.append(s.as_str());
                }
            },
            default => {
                var t: std::string = {};
                v.write(&t);
                if (escape_it) {
                    escape(t.as_str(), out);
                } else {
                    out.append(t.as_str());
                }
            },
        }
    }

    // is the value true for an {{if}}: true, a non-empty string, array or object, a number other
    // than 0
    fn truthy(v: std::json::value&) -> bool {
        match (*v) {
            .NULL => { return false; },
            .BOOL(b) => { return b; },
            .NUM(x) => { return x != 0.0; },
            .STR(s&) => { return s.len() > 0; },
            default => { return v.len() > 0; },
        }
    }

    // ---------- templates checked while compiling ----------

    // template src (usually @embed("page.html")) with data's values, after out's text. src is checked
    // against data's type T while compiling: it parses, each slot's and loop's path names a field of T
    // or of a loop's element, a loop goes over a std::vec, a slot shows text, a number or a bool, and
    // a path goes into an optional only inside an {{if}} on it. Anything else is a compile error that
    // names the line and the tag. T derives json (@derive(json)), and so do the structs in it: the
    // values come from to_json(), so rendering can't fail.
    //   std::html::render(@embed("page.html"), &p, &out);
    <T: type>
    public fn render(comptime src: str, data: T&, out: std::string&) -> void {
        ct_check(T, src);
        // ponytail: parses src at each call; keep the parsed template once a page renders often
        val t = template::parse(src) catch @panic("std::html::render: the template was checked while compiling");
        val v = data.to_json();
        t.render(&v, out) catch @panic("std::html::render: the template was checked while compiling");
    }

    // src's tags checked against T (see render), in one pass. The blocks open at a tag are a stack in
    // a string, innermost last, each "KIND NAME PATH LINE;": KIND f (a for: NAME in PATH), i (an if
    // on PATH, before its else; NAME -) or e (past its else); LINE where it opened
    comptime fn ct_check(T: type, src: str) -> void {
        if (!@attaches(T, std::derive::json)) {
            @compile_error("std::html::render: " + @typeinfo(T).short_name + " needs @attributes([@derive(json)])");
        }
        var blocks = "";
        var line: usize = 1;
        var seen: usize = 0;
        var open = ct_find(src, "{{", 0);
        while (open < src.len) {
            while (seen < open) {
                if (src[seen] == '\n') {
                    line += 1;
                }
                seen += 1;
            }
            val raw = open + 2 < src.len && src[open + 2] == '{';
            var close = "}}";
            if (raw) {
                close = "}}}";
            }
            val c = ct_find(src, close, open + close.len);
            if (c == src.len) {
                @compile_error("line " + ct_num(line) + ": " + src[open..open + close.len] + ": no " + close + " after it");
            }
            val end = c + close.len;
            val w = "line " + ct_num(line) + ": " + src[open..end];
            if (raw) {
                ct_slot(T, blocks, src[open + 3..c], w);
            } else {
                val tag = ct_trim(src[open + 2..c]);
                if (tag == "end") {
                    if (blocks.len == 0) {
                        @compile_error(w + ": nothing open for it");
                    }
                    blocks = blocks[0..ct_last_start(blocks)];
                } else if (tag == "else") {
                    val at = ct_last_start(blocks);
                    if (blocks.len == 0 || blocks[at] != 'i') {
                        @compile_error(w + ": not in an {{if}} (or a second {{else}})");
                    }
                    blocks = blocks[0..at] + "e" + blocks[at + 1..blocks.len];
                } else if (ct_starts(tag, "for ")) {
                    val rest = ct_trim(tag[4..tag.len]);
                    val sp = ct_find(rest, " in ", 0);
                    if (sp == rest.len) {
                        @compile_error(w + ": a loop is {{for name in path}}");
                    }
                    val name = ct_trim(rest[0..sp]);
                    val path = ct_trim(rest[sp + 4..rest.len]);
                    ct_path(name, w);
                    ct_path(path, w);
                    if (ct_find(name, ".", 0) < name.len) {
                        @compile_error(w + ": a loop's name is one word");
                    }
                    ct_elem(ct_type(T, blocks, path, w, false), w);
                    blocks = blocks + "f " + name + " " + path + " " + ct_num(line) + ";";
                } else if (ct_starts(tag, "if ")) {
                    val path = ct_trim(tag[3..tag.len]);
                    ct_path(path, w);
                    ct_type(T, blocks, path, w, true);
                    blocks = blocks + "i - " + path + " " + ct_num(line) + ";";
                } else {
                    ct_slot(T, blocks, tag, w);
                }
            }
            open = ct_find(src, "{{", end);
        }
        if (blocks.len > 0) {
            // the innermost block left open: its kind and line
            val at = ct_last_start(blocks);
            val e = ct_entry(blocks, at);
            var what = "{{for " + ct_word(e, 1) + " in " + ct_word(e, 2) + "}}";
            if (e[0] != 'f') {
                what = "{{if " + ct_word(e, 2) + "}}";
            }
            @compile_error("line " + ct_word(e, 3) + ": " + what + ": no {{end}} for it");
        }
    }

    // a slot's path: text, a number or a bool (an optional one inside an {{if}} on it)
    comptime fn ct_slot(T: type, blocks: str, path: str, w: str) -> void {
        ct_path(path, w);
        val V = ct_unopt(ct_type(T, blocks, path, w, false), blocks, path, w);
        if (V == str || V == std::string || V == bool) {
            return;
        }
        comptime match (@typeinfo(V).kind) {
            .INT(i) => { return; },
            .FLOAT(f) => { return; },
            default => {
                @compile_error(w + ": a slot shows text, a number or a bool, not " + @typeinfo(V).short_name);
            },
        }
    }

    // the type at path with blocks open (w: the tag): its first name the variable of the innermost
    // open loop of that name or a field of T, then fields; an optional on the way only inside an
    // {{if}} on it, unless the tag is an if (in_if: null is false there)
    comptime fn ct_type(T: type, blocks: str, path: str, w: str, in_if: bool) -> type {
        val dot = ct_find(path, ".", 0);
        val first = path[0..dot];
        var V: type = T;
        val l = ct_loop(blocks, first);
        if (l < blocks.len) {
            // the loop's path, as the blocks outside it see it
            val e = ct_entry(blocks, l);
            val lw = "line " + ct_word(e, 3) + ": {{for " + first + " in " + ct_word(e, 2) + "}}";
            V = ct_elem(ct_type(T, blocks[0..l], ct_word(e, 2), lw, false), lw);
        } else {
            V = ct_field(T, first, w);
        }
        var at = dot;
        while (at < path.len) {
            if (in_if) {
                V = ct_opt_inner(V);
            } else {
                V = ct_unopt(V, blocks, path[0..at], w);
            }
            val next = ct_find(path, ".", at + 1);
            V = ct_field(V, path[at + 1..next], w);
            at = next;
        }
        return V;
    }

    // V's field name
    comptime fn ct_field(V: type, name: str, w: str) -> type {
        comptime for (f) in @typeinfo(V).fields {
            if (f.name == name) {
                return f.field_type;
            }
        }
        @compile_error(w + ": " + @typeinfo(V).short_name + " has no field " + name);
    }

    // what V holds when it's an optional (V when it isn't)
    comptime fn ct_opt_inner(V: type) -> type {
        comptime match (@typeinfo(V).kind) {
            .OPTIONAL(x) => { return x; },
            default => { return V; },
        }
    }

    // V's value at path, which may be null when V is an optional: fine inside an {{if path}}'s
    // first part
    comptime fn ct_unopt(V: type, blocks: str, path: str, w: str) -> type {
        val x = ct_opt_inner(V);
        // (every entry follows a ;)
        if (x != V && ct_find(";" + blocks, ";i - " + path + " ", 0) > blocks.len) {
            @compile_error(w + ": " + path + " can be null: use it inside {{if " + path + "}}");
        }
        return x;
    }

    // what a loop over V goes through: a std::vec's elements
    comptime fn ct_elem(V: type, w: str) -> type {
        if (!ct_starts(@typeinfo(V).canonical_name, "std::vec<")) {
            @compile_error(w + ": a loop goes over a std::vec, not " + @typeinfo(V).short_name);
        }
        return @typeinfo(V).generic_args[0];
    }

    // where the innermost open loop named name starts in blocks (blocks.len: none)
    comptime fn ct_loop(blocks: str, name: str) -> usize {
        var end = blocks.len;
        while (end > 0) {
            val at = ct_last_start(blocks[0..end]);
            val e = ct_entry(blocks, at);
            if (e[0] == 'f' && ct_word(e, 1) == name) {
                return at;
            }
            end = at;
        }
        return blocks.len;
    }

    // where the last entry of blocks starts (0 when there's one or none)
    comptime fn ct_last_start(blocks: str) -> usize {
        if (blocks.len < 2) {
            return 0;
        }
        var i = blocks.len - 1;
        while (i > 0) {
            if (blocks[i - 1] == ';') {
                return i;
            }
            i -= 1;
        }
        return 0;
    }

    // the entry of blocks at at, without its ;
    comptime fn ct_entry(blocks: str, at: usize) -> str {
        return blocks[at..ct_find(blocks, ";", at)];
    }

    // word k (from 0) of an entry
    comptime fn ct_word(e: str, k: usize) -> str {
        var at: usize = 0;
        var n: usize = 0;
        while (n < k) {
            at = ct_find(e, " ", at) + 1;
            n += 1;
        }
        return e[at..ct_find(e, " ", at)];
    }

    // a path as parse reads them (see path_of): names of letters, digits and _, joined by dots
    comptime fn ct_path(s: str, w: str) -> void {
        var ok = s.len > 0 && s != "if" && s != "for" && s != "end" && s != "else";
        var dot = true;
        var i: usize = 0;
        while (ok && i < s.len) {
            val c = s[i];
            if (c == '.') {
                ok = !dot;
                dot = true;
            } else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') {
                dot = false;
            } else {
                ok = false;
            }
            i += 1;
        }
        if (!ok || dot) {
            @compile_error(w + ": not a path (names joined by dots)");
        }
    }

    // n in decimal
    comptime fn ct_num(n: usize) -> str {
        val d = "0123456789";
        if (n < 10) {
            return d[n..n + 1];
        }
        return ct_num(n / 10) + d[n % 10..n % 10 + 1];
    }

    // where text is in s from from on (s.len: nowhere)
    comptime fn ct_find(s: str, text: str, from: usize) -> usize {
        var i = from;
        while (i + text.len <= s.len) {
            if (s[i..i + text.len] == text) {
                return i;
            }
            i += 1;
        }
        return s.len;
    }

    comptime fn ct_starts(s: str, p: str) -> bool {
        return s.len >= p.len && s[0..p.len] == p;
    }

    // s without white space at its ends, as str's trim
    comptime fn ct_trim(s: str) -> str {
        var a: usize = 0;
        var b = s.len;
        while (a < b && ct_space(s[a])) {
            a += 1;
        }
        while (b > a && ct_space(s[b - 1])) {
            b -= 1;
        }
        return s[a..b];
    }

    comptime fn ct_space(c: u8) -> bool {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0B || c == 0x0C;
    }
}
