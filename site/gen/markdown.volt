// Markdown to HTML: the subset the site's pages use, rendered as Astro's Markdown (remark with GFM
// and SmartyPants) and Starlight render it, so pages come out as they did. Blocks: headings (with
// ids and anchor links), paragraphs, lists, tables and fenced code (code.volt); inline: code, links,
// strong and em, with typographic quotes, dashes and ellipses in prose.
use std::fmt;
use std::html;
use std::json;

// a heading, for the table of contents
struct heading {
    depth: u32;        // 2 or 3
    id: std::string;
    text: std::string; // plain text, escaped
}

struct rendered {
    html: std::string;
    headings: std::vec<heading>;
}

// what rendering a page keeps track of
struct md_state {
    ids: std::vec<std::string>;      // heading ids taken
    headings: std::vec<heading>;
    code_blocks: usize = 0;
}

// md (a page without its frontmatter) as HTML; th has the code frame and heading templates
fn render_md(md: str, th: theme&) -> rendered {
    var st: md_state = { ids: {}, headings: {} };
    var html: std::string = {};
    val lines = md.lines();
    blocks(&lines, false, &st, th, &html);
    html.push('\n');
    return { html: move html, headings: copy st.headings };
}

// lines as blocks, each after a newline; in a tight list's item a paragraph has no <p>
fn blocks(lines: std::vec<str>&, tight: bool, st: md_state&, th: theme&, out: std::string&) -> void {
    var para: std::vec<str> = {};
    var i: usize = 0;
    while (i < lines.len) {
        val l = *lines.at(i);
        val t = l.trim();
        if (t.len == 0) {
            flush_para(&para, tight, out);
            i += 1;
            continue;
        }
        if (t.starts_with("<!--")) {
            // an HTML comment, kept as it is
            flush_para(&para, tight, out);
            block_start(out);
            while (i < lines.len) {
                val c = *lines.at(i);
                out.append(c);
                i += 1;
                if (c.contains("-->")) {
                    break;
                }
                out.push('\n');
            }
            continue;
        }
        if (t.starts_with("```")) {
            flush_para(&para, tight, out);
            val info = t[3..t.len].trim();
            var body: std::string = {};
            i += 1;
            while (i < lines.len && !(*lines.at(i)).trim().starts_with("```")) {
                body.append(*lines.at(i));
                body.push('\n');
                i += 1;
            }
            i += 1; // the closing fence
            block_start(out);
            code_frame(th, info, body.as_str(), st.code_blocks == 0, false, out);
            st.code_blocks += 1;
            continue;
        }
        if (t.starts_with("## ") || t.starts_with("### ")) {
            flush_para(&para, tight, out);
            var depth: u32 = 2;
            if (t.starts_with("### ")) {
                depth = 3;
            }
            val text = t[@cast<usize>(depth) + 1..t.len].trim();
            block_start(out);
            heading_block(depth, text, st, th, out);
            i += 1;
            continue;
        }
        if (t.starts_with("|") && para.len == 0) {
            var rows: std::vec<str> = {};
            while (i < lines.len && (*lines.at(i)).trim().starts_with("|")) {
                rows.push((*lines.at(i)).trim());
                i += 1;
            }
            block_start(out);
            table(&rows, out);
            continue;
        }
        // a list can interrupt a paragraph (an ordered one only from 1)
        val interrupts = t.starts_with("- ") || t.starts_with("* ") || t.starts_with("1. ");
        if (item_start(l) != null && (para.len == 0 || interrupts)) {
            flush_para(&para, tight, out);
            block_start(out);
            i = list(lines, i, st, th, out);
            continue;
        }
        para.push(t);
        i += 1;
    }
    flush_para(&para, tight, out);
}

// blocks are separated by a newline
fn block_start(out: std::string&) -> void {
    if (out.len() > 0) {
        out.push('\n');
    }
}

fn flush_para(para: std::vec<str>&, tight: bool, out: std::string&) -> void {
    if (para.len == 0) {
        return;
    }
    block_start(out);
    if (!tight) {
        out.append("<p>");
    }
    var text: std::string = {};
    for (l&, i) in para.items() {
        if (i > 0) {
            text.push('\n');
        }
        text.append(*l);
    }
    inline(text.as_str(), out);
    if (!tight) {
        out.append("</p>");
    }
    para.clear();
}

// ---------- headings ----------

fn heading_block(depth: u32, text: str, st: md_state&, th: theme&, out: std::string&) -> void {
    var plain: std::string = {};
    plain_text(text, &plain);
    var id = slug(plain.as_str(), &st.ids);
    var shown: std::string = {};
    smart_escape(plain.as_str(), &shown);
    var html: std::string = {};
    inline(text, &html);
    var d = std::json::object();
    d.set("depth", std::json::number(@cast<f64>(depth)));
    d.set("id", std::json::string(id.as_str()));
    d.set("html", std::json::string(html.as_str()));
    d.set("shown", std::json::string(shown.as_str()));
    fill(&th.heading, &d, out);
    st.headings.push({ depth: depth, id: move id, text: move shown });
}

// a heading's text without its markup: code spans' contents, link texts
fn plain_text(s: str, out: std::string&) -> void {
    var i: usize = 0;
    while (i < s.len) {
        val c = s[i];
        if (c == '`') {
            val close = s[i + 1..s.len].find("`") ?? (s.len - i - 1);
            out.append(s[i + 1..i + 1 + close]);
            i += close + 2;
            continue;
        }
        if (c == '*') {
            i += 1;
            continue;
        }
        if (c == '&' && entity(s[i..s.len]) != null) {
            val e = entity(s[i..s.len]) ?? 1;
            val name = s[i..i + e];
            if (name == "&lt;") {
                out.push('<');
            } else if (name == "&gt;") {
                out.push('>');
            } else if (name == "&amp;") {
                out.push('&');
            } else if (name == "&quot;") {
                out.push('"');
            }
            i += e;
            continue;
        }
        // a link: its text
        val close = matching(s, i, '[', ']') ?? 0;
        if (c == '[' && close > 0 && close + 1 < s.len && s[close + 1] == '(') {
            plain_text(s[i + 1..close], out);
            i = close + 1 + (s[close..s.len].find(")") ?? 0);
            continue;
        }
        out.push(c);
        i += 1;
    }
}

// github-slugger: lower case, punctuation dropped, spaces to dashes; a repeated id gets -1, -2, ...
fn slug(text: str, ids: std::vec<std::string>&) -> std::string {
    var s: std::string = {};
    var i: usize = 0;
    while (i < text.len) {
        val c = text[i];
        if (c >= 'A' && c <= 'Z') {
            s.push(c + 32);
        } else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            s.push(c);
        } else if (c == ' ') {
            s.push('-');
        } else if (c >= 0x80) {
            // a UTF-8 sequence: typographic punctuation (U+2000..U+206F) goes, letters stay
            var n: usize = 2;
            if (c >= 0xF0) {
                n = 4;
            } else if (c >= 0xE0) {
                n = 3;
            }
            val punct = c == 0xE2 && i + 1 < text.len && text[i + 1] == 0x80;
            if (!punct) {
                s.append(text[i..i + n]);
            }
            i += n;
            continue;
        }
        i += 1;
    }
    var id = copy s;
    var n: usize = 1;
    while (taken(ids, id.as_str())) {
        id = std::format("{}-{}", s.as_str(), n);
        n += 1;
    }
    ids.push(copy id);
    return id;
}

fn taken(ids: std::vec<std::string>&, id: str) -> bool {
    for (x&) in ids.items() {
        if (x.as_str() == id) {
            return true;
        }
    }
    return false;
}

// ---------- lists ----------

// where an item's text starts in l, when l starts a list item ("- ", "1. ")
fn item_start(l: str) -> usize? {
    val t = l.trim_start();
    val indent = l.len - t.len;
    if (t.starts_with("- ") || t.starts_with("* ")) {
        return indent + 2;
    }
    var d: usize = 0;
    while (d < t.len && t[d] >= '0' && t[d] <= '9') {
        d += 1;
    }
    if (d > 0 && d + 1 < t.len && t[d] == '.' && t[d + 1] == ' ') {
        return indent + d + 2;
    }
    return null;
}

// the list starting at lines[start]; returns the line after it. An item's lines go on while they're
// indented to its text (or continue its paragraph); a blank line inside an item or between items
// makes the list loose, and a loose list's paragraphs are <p>s
fn list(lines: std::vec<str>&, start: usize, st: md_state&, th: theme&, out: std::string&) -> usize {
    val first = *lines.at(start);
    val ordered = !first.trim_start().starts_with("-") && !first.trim_start().starts_with("*");
    var items: std::vec<std::vec<str>> = {};
    var loose = false;
    var i = start;
    while (i < lines.len) {
        val l = *lines.at(i);
        val at = item_start(l) ?? break;
        var item: std::vec<str> = {};
        item.push(l[at..l.len]);
        i += 1;
        while (i < lines.len) {
            val n = *lines.at(i);
            if (n.trim().len == 0) {
                var j = i;
                while (j < lines.len && (*lines.at(j)).trim().len == 0) {
                    j += 1;
                }
                if (j < lines.len && indent_of(*lines.at(j)) >= at) {
                    loose = true;
                    for (k) in i..j {
                        item.push("");
                    }
                    i = j;
                    continue;
                }
                break;
            }
            if (indent_of(n) >= at) {
                item.push(n[at..n.len]);
            } else if (item_start(n) != null || n.trim().starts_with("```") || n.trim().starts_with("#") || n.trim().starts_with("|")) {
                break;
            } else {
                item.push(n.trim());
            }
            i += 1;
        }
        items.push(move item);
        if (i < lines.len && (*lines.at(i)).trim().len == 0) {
            var j = i;
            while (j < lines.len && (*lines.at(j)).trim().len == 0) {
                j += 1;
            }
            if (j < lines.len && item_start(*lines.at(j)) != null && indent_of(*lines.at(j)) == indent_of(first)) {
                loose = true;
                i = j;
                continue;
            }
            break;
        }
    }
    out.append(either(ordered, "<ol>", "<ul>"));
    for (item&) in items.items() {
        var inner: std::string = {};
        blocks(item, !loose, st, th, &inner);
        if (loose) {
            out.append("\n<li>\n");
            out.append(inner.as_str());
            out.append("\n</li>");
        } else {
            out.append("\n<li>");
            out.append(inner.as_str());
            out.append("</li>");
        }
    }
    out.append(either(ordered, "\n</ol>", "\n</ul>"));
    return i;
}

fn indent_of(l: str) -> usize {
    return l.len - l.trim_start().len;
}

// ---------- tables ----------

fn table(rows: std::vec<str>&, out: std::string&) -> void {
    // the separator row's colons: :-- left, --: right, :-: center
    var align: std::vec<str> = {};
    if (rows.len > 1) {
        for (c&) in cells(*rows.at(1)).items() {
            val left = c.as_str().starts_with(":");
            val right = c.as_str().ends_with(":");
            if (left && right) {
                align.push(" style=\"text-align: center\"");
            } else if (right) {
                align.push(" style=\"text-align: right\"");
            } else if (left) {
                align.push(" style=\"text-align: left\"");
            } else {
                align.push("");
            }
        }
    }
    out.append("<table>\n<thead>\n<tr>");
    for (c&, k) in cells(*rows.at(0)).items() {
        std::write(out, "\n<th{}>", column(&align, k));
        inline(c.as_str(), out);
        out.append("</th>");
    }
    out.append("\n</tr>\n</thead>");
    if (rows.len > 2) {
        out.append("\n<tbody>");
        for (r) in 2..rows.len {
            out.append("\n<tr>");
            for (c&, k) in cells(*rows.at(r)).items() {
                std::write(out, "\n<td{}>", column(&align, k));
                inline(c.as_str(), out);
                out.append("</td>");
            }
            out.append("\n</tr>");
        }
        out.append("\n</tbody>");
    }
    out.append("\n</table>");
}

fn column(align: std::vec<str>&, k: usize) -> str {
    if (k < align.len) {
        return *align.at(k);
    }
    return "";
}

// a table row's cells: split at | outside code spans, trimmed; \| is a | in the cell
fn cells(row: str) -> std::vec<std::string> {
    var v: std::vec<std::string> = {};
    var r = row.trim();
    if (r.starts_with("|")) {
        r = r[1..r.len];
    }
    if (r.ends_with("|") && !r.ends_with("\\|")) {
        r = r[0..r.len - 1];
    }
    var cell: std::string = {};
    var code = false;
    var i: usize = 0;
    while (i < r.len) {
        val c = r[i];
        if (c == '\\' && i + 1 < r.len && r[i + 1] == '|') {
            cell.push('|');
            i += 2;
            continue;
        }
        if (c == '`') {
            code = !code;
        }
        if (c == '|' && !code) {
            v.push(std::string::from(cell.as_str().trim()));
            cell.clear();
        } else {
            cell.push(c);
        }
        i += 1;
    }
    v.push(std::string::from(cell.as_str().trim()));
    return v;
}

// ---------- inline ----------

// inline markup to HTML: code spans, links, **strong**, *em*, and prose with SmartyPants
fn inline(s: str, out: std::string&) -> void {
    var i: usize = 0;
    var text_from: usize = 0;
    while (i < s.len) {
        val c = s[i];
        if (c == '`') {
            var n: usize = 0;
            while (i + n < s.len && s[i + n] == '`') {
                n += 1;
            }
            val fence = s[i..i + n];
            val close = s[i + n..s.len].find(fence);
            if (close) {
                smart_text(s[text_from..i], before(s, text_from), out);
                var body = s[i + n..i + n + close];
                if (body.len > 1 && body[0] == ' ' && body[body.len - 1] == ' ') {
                    body = body[1..body.len - 1];
                }
                out.append("<code dir=\"auto\">");
                // a line break inside a code span is a space
                for (k) in 0..body.len {
                    if (body[k] == '\n') {
                        out.push(' ');
                    } else {
                        escape_char(body[k], out);
                    }
                }
                out.append("</code>");
                i = i + n + close + n;
                text_from = i;
                continue;
            }
        }
        if (c == '[') {
            val close = matching(s, i, '[', ']');
            if (close != null && (close ?? 0) + 1 < s.len && s[(close ?? 0) + 1] == '(') {
                val end = s[(close ?? 0)..s.len].find(")");
                if (end) {
                    smart_text(s[text_from..i], before(s, text_from), out);
                    val url = s[(close ?? 0) + 2..(close ?? 0) + end];
                    out.append("<a href=\"");
                    std::html::escape(url, out);
                    out.append("\">");
                    inline(s[i + 1..(close ?? 0)], out);
                    out.append("</a>");
                    i = (close ?? 0) + end + 1;
                    text_from = i;
                        continue;
                }
            }
        }
        if (c == '*' && i + 1 < s.len && s[i + 1] == '*') {
            val close = s[i + 2..s.len].find("**");
            if (close) {
                smart_text(s[text_from..i], before(s, text_from), out);
                out.append("<strong>");
                inline(s[i + 2..i + 2 + close], out);
                out.append("</strong>");
                i = i + 2 + close + 2;
                text_from = i;
                continue;
            }
        }
        if (c == '*' && i + 1 < s.len && s[i + 1] != ' ' && s[i + 1] != '*') {
            val close = s[i + 1..s.len].find("*") ?? 0;
            if (close > 0 && s[i + close] != ' ') {
                smart_text(s[text_from..i], before(s, text_from), out);
                out.append("<em>");
                inline(s[i + 1..i + 1 + close], out);
                out.append("</em>");
                i = i + 1 + close + 1;
                text_from = i;
                continue;
            }
        }
        i += 1;
    }
    smart_text(s[text_from..s.len], before(s, text_from), out);
}

// the character before s[at], for quotes: what came before a run of prose (a space at the start)
fn before(s: str, at: usize) -> u8 {
    if (at == 0) {
        return ' ';
    }
    return s[at - 1];
}

// where the bracket matching s[at] closes
fn matching(s: str, at: usize, open: u8, close: u8) -> usize? {
    var depth = 0;
    var code = false;
    for (i) in at..s.len {
        if (s[i] == '`') {
            code = !code;
        } else if (!code && s[i] == open) {
            depth += 1;
        } else if (!code && s[i] == close) {
            depth -= 1;
            if (depth == 0) {
                return i;
            }
        }
    }
    return null;
}

// prose: escaped, with SmartyPants' quotes, dashes and ellipses; before is the character before it
fn smart_text(s: str, before: u8, out: std::string&) -> void {
    var prev = before;
    var i: usize = 0;
    while (i < s.len) {
        val c = s[i];
        val opens = prev == ' ' || prev == '\n' || prev == '(' || prev == '[' || prev == '{';
        if (c == '"') {
            out.append(either(opens, "“", "”"));
        } else if (c == '\'') {
            out.append(either(opens, "‘", "’"));
        } else if (c == '-' && i + 2 < s.len && s[i + 1] == '-' && s[i + 2] == '-') {
            out.append("—");
            i += 2;
        } else if (c == '-' && i + 1 < s.len && s[i + 1] == '-') {
            out.append("–");
            i += 1;
        } else if (c == '.' && i + 2 < s.len && s[i + 1] == '.' && s[i + 2] == '.') {
            out.append("…");
            i += 2;
        } else if (c == '&' && entity(s[i..s.len]) != null) {
            // an entity is HTML already
            val e = entity(s[i..s.len]) ?? 1;
            out.append(s[i..i + e]);
            i += e - 1;
        } else {
            escape_char(c, out);
        }
        prev = c;
        i += 1;
    }
}

// a heading's plain text for the anchor's label and the table of contents
fn smart_escape(s: str, out: std::string&) -> void {
    smart_text(s, ' ', out);
}

// the length of the character reference s starts with (&lt; &gt; &amp; &quot;), if it does
fn entity(s: str) -> usize? {
    val names: str[4] = { "&lt;", "&gt;", "&amp;", "&quot;" };
    for (e) in names {
        if (s.starts_with(e)) {
            return e.len;
        }
    }
    return null;
}

fn either(c: bool, a: str, b: str) -> str {
    if (c) {
        return a;
    }
    return b;
}

fn escape_char(c: u8, out: std::string&) -> void {
    if (c == '&') {
        out.append("&amp;");
    } else if (c == '<') {
        out.append("&lt;");
    } else if (c == '>') {
        out.append("&gt;");
    } else {
        out.push(c);
    }
}
