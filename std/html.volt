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
// the data. Text can't hold a {{ of its own: give it as a value.

namespace html {
    // why a template can't be parsed (SYNTAX), read from its file (READ) or rendered (MISSING: a
    // slot or a loop names a value the data doesn't have)
    public error template_error {
        SYNTAX,
        MISSING,
        READ,
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
        SLOT: std::string,  // {{path}}
        RAW: std::string,   // {{{path}}}
        FOR: each,          // {{for name in path}}body{{end}}
        IF: branch,         // {{if path}}yes{{else}}no{{end}}
    }

    struct each {
        name: std::string;
        path: std::string;
        body: std::vec<node>;
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
            // an {{end}} or {{else}} with nothing open
            return template_error::SYNTAX;
        }
        return t;
    }

    // the template in file path
    public attach fn read(static this: template, path: str) -> template_error!template {
        val src = std::fs::read_file(path) catch |e| {
            return template_error::READ;
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
                val close = find_from(src, "}}}", open + 3) ?? return template_error::SYNTAX;
                out.push(node::RAW(try path_of(src[open + 3..close]))) catch @panic("out of memory");
                *at = close + 3;
                continue;
            }
            val close = find_from(src, "}}", open + 2) ?? return template_error::SYNTAX;
            val tag = src[open + 2..close].trim();
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
                val sp = rest.find(" in ") ?? return template_error::SYNTAX;
                var l: each = { name: try path_of(rest[0..sp].trim()), path: try path_of(rest[sp + 4..].trim()), body: {} };
                if (l.name.as_str().find(".") != null || try parse_nodes(src, at, &l.body) != 1) {
                    return template_error::SYNTAX;
                }
                out.push(node::FOR(move l)) catch @panic("out of memory");
                continue;
            }
            if (tag.starts_with("if ")) {
                var b: branch = { path: try path_of(tag[3..].trim()), yes: {}, no: {} };
                val ended = try parse_nodes(src, at, &b.yes);
                if (ended == 2) {
                    if (try parse_nodes(src, at, &b.no) != 1) {
                        return template_error::SYNTAX;
                    }
                } else if (ended != 1) {
                    return template_error::SYNTAX;
                }
                out.push(node::IF(move b)) catch @panic("out of memory");
                continue;
            }
            out.push(node::SLOT(try path_of(tag))) catch @panic("out of memory");
        }
        return 0;
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
                    val v = lookup(p.as_str(), data, scopes);
                    try put_value(v, true, out);
                },
                .RAW(p&) => {
                    val v = lookup(p.as_str(), data, scopes);
                    try put_value(v, false, out);
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
                        default => { return template_error::MISSING; },
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
}
