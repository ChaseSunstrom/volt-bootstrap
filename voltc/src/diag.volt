// Showing diagnostics: the human format (the source lines underlined, ^ for the error's span and -
// for its labels, then help lines; in colour on a terminal), one line per diagnostic (short), or
// JSON for tools. A port of bootstrap/diag.rs that prints the same bytes.
use std::mem;

// no place in the source (an error about the program as a whole): only the message is shown
val NO_SPAN: span = { file: 4294967295, lo: 0, hi: 0 };

// --message-format
val FORMAT_HUMAN: u8 = 0;
val FORMAT_SHORT: u8 = 1;
val FORMAT_JSON: u8 = 2;

// ANSI styles for the human format
val RED: str = "\x1b[1;31m";
val YELLOW: str = "\x1b[1;33m";
val BLUE: str = "\x1b[1;34m";
val BOLD: str = "\x1b[1m";
val RESET: str = "\x1b[0m";

// the 1-based line and column (in characters, a tab is one) of byte offset at in a file
fn text_pos(text: str, at0: usize) -> (line: usize, col: usize) {
    var at = at0;
    if (at > text.len) {
        at = text.len;
    }
    while (at > 0 && at < text.len && (text[at] & 0xC0) == 0x80) {
        at -= 1;
    }
    var line: usize = 1;
    var col: usize = 1;
    for (i) in 0..at {
        if (text[i] == '\n') {
            line += 1;
            col = 1;
        } else if ((text[i] & 0xC0) != 0x80) {
            col += 1;
        }
    }
    return { line: line, col: col };
}

// the byte offset of at within its line
fn byte_col(text: str, at0: usize) -> usize {
    var at = at0;
    if (at > text.len) {
        at = text.len;
    }
    var i = at;
    while (i > 0 && text[i - 1] != '\n') {
        i -= 1;
    }
    return at - i;
}

// line n (1-based) of a text, without its line break
fn text_line(text: str, n: usize) -> str {
    var line: usize = 1;
    var i: usize = 0;
    while (i < text.len && line < n) {
        if (text[i] == '\n') {
            line += 1;
        }
        i += 1;
    }
    var j = i;
    while (j < text.len && text[j] != '\n') {
        j += 1;
    }
    if (j > i && text[j - 1] == '\r') {
        j -= 1;
    }
    return text[i..j];
}

// display width: characters, a tab counting 4 (the human format shows tabs as 4 spaces)
fn width(s: str) -> usize {
    var w: usize = 0;
    for (c) in s {
        if (c == '\t') {
            w += 4;
        } else if ((c & 0xC0) != 0x80) {
            w += 1;
        }
    }
    return w;
}

fn digits(v: usize) -> usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) {
        x = x / 10;
        n += 1;
    }
    return n;
}

fn push_n(s: std::string&, c: u8, n: usize) -> void {
    for (i) in 0..n {
        s.push(c);
    }
}

// part in style, when colours are on
fn paint(out: std::string&, color: bool, style: str, part: str) -> void {
    if (color && part.len > 0) {
        out.append(style);
        out.append(part);
        out.append(RESET);
    } else {
        out.append(part);
    }
}

// `file:line:col` of a span's start
fn span_loc(files: std::vec<source_file>&, sp: span) -> std::string {
    val f = files.at(@cast<usize>(sp.file));
    val p = text_pos(f.text, @cast<usize>(sp.lo));
    var s = S(f.name);
    s.push(':');
    s.append_uint(@cast<u64>(p.line));
    s.push(':');
    s.append_uint(@cast<u64>(p.col));
    return move s;
}

fn kind_of_diag(d: diag&) -> str {
    if (d.warning) {
        return "warning";
    }
    return "error";
}

// one underline: the line it's on, its columns, whether it's the error's own span, its text
struct mark_row {
    line: usize;
    start: usize;
    end: usize;
    primary: bool;
    msg: str;
}

// the human format: the message, then per file the source lines with their underlines, then the
// help lines
fn render_human(files: std::vec<source_file>&, d: diag&, color: bool) -> std::string {
    var tone = RED;
    if (d.warning) {
        tone = YELLOW;
    }
    var out: std::string = {};
    paint(&out, color, tone, kind_of_diag(d));
    if (d.diff && color) {
        diff_msg(&out, d.msg.as_str());
    } else {
        var head = S(": ");
        head.append(d.msg.as_str());
        paint(&out, color, BOLD, head.as_str());
    }
    // the main span, then the labels; one block per file, the main span's file first
    var spans: std::vec<span> = {};
    var texts: std::vec<str> = {};
    var mains: std::vec<bool> = {};
    if (!same_span(d.span, NO_SPAN)) {
        put(&spans, d.span);
        put(&texts, "");
        put(&mains, true);
    }
    for (l&) in d.labels.items() {
        put(&spans, l.span);
        put(&texts, l.msg.as_str());
        put(&mains, false);
    }
    var order: std::vec<u32> = {};
    for (s&) in spans.items() {
        var seen = false;
        for (f&) in order.items() {
            if (*f == s.file) {
                seen = true;
            }
        }
        if (!seen) {
            put(&order, s.file);
        }
    }
    // one gutter width for the whole diagnostic, so every block lines up
    var w: usize = 1;
    var first_w = true;
    for (s&) in spans.items() {
        val n = digits(text_pos(files.at(@cast<usize>(s.file)).text, @cast<usize>(s.lo)).line);
        if (first_w || n > w) {
            w = n;
            first_w = false;
        }
    }
    var pad: std::string = {};
    push_n(&pad, ' ', w + 1);
    for (bi) in 0..order.len {
        val f = *order.at(bi);
        val text = files.at(@cast<usize>(f)).text;
        var first: usize = 0;
        while (spans.at(first).file != f) {
            first += 1;
        }
        if (bi > 0) {
            out.push('\n');
            out.append(pad.as_str());
            paint(&out, color, BLUE, "│");
        }
        out.push('\n');
        out.append(pad.as_str());
        paint(&out, color, BLUE, "┌─");
        out.push(' ');
        out.append(span_loc(files, *spans.at(first)).as_str());
        out.push('\n');
        out.append(pad.as_str());
        paint(&out, color, BLUE, "│");
        // the rows, in line then column order (a stable insertion sort, as Rust's sort_by_key)
        var rows: std::vec<mark_row> = {};
        for (k) in 0..spans.len {
            val s = *spans.at(k);
            if (s.file != f) {
                continue;
            }
            val lo = @cast<usize>(s.lo);
            val hi = @cast<usize>(s.hi);
            val p0 = text_pos(text, lo);
            val line_text = text_line(text, p0.line);
            val line_start = lo - byte_col(text, lo);
            var a = lo - line_start;
            if (a > line_text.len) {
                a = line_text.len;
            }
            val start = width(line_text[0..a]);
            var end = width(line_text);
            if (text_pos(text, hi).line == p0.line) {
                var b = hi - line_start;
                if (b > line_text.len) {
                    b = line_text.len;
                }
                end = width(line_text[0..b]);
            }
            if (end < start + 1) {
                end = start + 1;
            }
            val row: mark_row = { line: p0.line, start: start, end: end, primary: *mains.at(k), msg: *texts.at(k) };
            var at = rows.len;
            while (at > 0 && (rows.at(at - 1).line > row.line || (rows.at(at - 1).line == row.line && rows.at(at - 1).start > row.start))) {
                at -= 1;
            }
            put(&rows, row);
            var m = rows.len - 1;
            while (m > at) {
                val tmp = *rows.at(m - 1);
                *rows.at(m - 1) = *rows.at(m);
                *rows.at(m) = tmp;
                m -= 1;
            }
        }
        var last: usize = 0;
        for (r&) in rows.items() {
            if (last != r.line) {
                if (last != 0 && r.line > last + 1) {
                    out.push('\n');
                    out.append(pad.as_str());
                    paint(&out, color, BLUE, "·");
                }
                // the line number, right-aligned, and the source line with tabs shown as spaces
                var num_s: std::string = {};
                push_n(&num_s, ' ', w - digits(r.line));
                num_s.append_uint(@cast<u64>(r.line));
                out.push('\n');
                paint(&out, color, BLUE, num_s.as_str());
                out.push(' ');
                paint(&out, color, BLUE, "│");
                var shown: std::string = {};
                for (c) in text_line(text, r.line) {
                    if (c == '\t') {
                        shown.append("    ");
                    } else {
                        shown.push(c);
                    }
                }
                var n = shown.len();
                while (n > 0 && (*shown.bytes.at(n - 1) == ' ' || *shown.bytes.at(n - 1) == '\t' || *shown.bytes.at(n - 1) == '\r')) {
                    n -= 1;
                }
                if (n > 0) {
                    out.push(' ');
                    out.append(shown.as_str()[0..n]);
                } else {
                    out.push(' ');
                }
                last = r.line;
            }
            var style = BLUE;
            var ch: u8 = '-';
            if (r.primary) {
                style = tone;
                ch = '^';
            }
            var marks: std::string = {};
            push_n(&marks, ch, r.end - r.start);
            if (r.msg.len > 0) {
                marks.push(' ');
                marks.append(r.msg);
            }
            out.push('\n');
            out.append(pad.as_str());
            paint(&out, color, BLUE, "│");
            out.push(' ');
            push_n(&out, ' ', r.start);
            paint(&out, color, style, marks.as_str());
        }
    }
    if (d.notes.len > 0) {
        if (spans.len > 0) {
            out.push('\n');
            out.append(pad.as_str());
            paint(&out, color, BLUE, "│");
        }
        for (n&) in d.notes.items() {
            val t = n.as_str();
            var kind = "note";
            var rest = t;
            var i: usize = 0;
            while (i + 1 < t.len) {
                if (t[i] == ':' && t[i + 1] == ' ') {
                    kind = t[0..i];
                    rest = t[i + 2..t.len];
                    break;
                }
                i += 1;
            }
            out.push('\n');
            out.append(pad.as_str());
            paint(&out, color, BLUE, "=");
            out.push(' ');
            paint(&out, color, BOLD, kind);
            out.append(": ");
            out.append(rest);
        }
    }
    return move out;
}

// a JSON string literal
fn json_str(out: std::string&, s: str) -> void {
    out.push('"');
    for (c) in s {
        if (c == '"') {
            out.append("\\\"");
        } else if (c == '\\') {
            out.append("\\\\");
        } else if (c == '\n') {
            out.append("\\n");
        } else if (c == '\t') {
            out.append("\\t");
        } else if (c < 0x20) {
            out.append("\\u00");
            val hex = "0123456789abcdef";
            out.push(hex[@cast<usize>(c / 16)]);
            out.push(hex[@cast<usize>(c % 16)]);
        } else {
            out.push(c);
        }
    }
    out.push('"');
}

// "file":..,"line":..,"column":..,"end_line":..,"end_column":..
fn json_place(out: std::string&, files: std::vec<source_file>&, s: span) -> void {
    val f = files.at(@cast<usize>(s.file));
    val a = text_pos(f.text, @cast<usize>(s.lo));
    val b = text_pos(f.text, @cast<usize>(s.hi));
    out.append("\"file\":");
    json_str(out, f.name);
    out.append(",\"line\":");
    out.append_uint(@cast<u64>(a.line));
    out.append(",\"column\":");
    out.append_uint(@cast<u64>(a.col));
    out.append(",\"end_line\":");
    out.append_uint(@cast<u64>(b.line));
    out.append(",\"end_column\":");
    out.append_uint(@cast<u64>(b.col));
}

fn render_json(files: std::vec<source_file>&, d: diag&) -> std::string {
    var out = S("{\"severity\":\"");
    out.append(kind_of_diag(d));
    out.append("\",\"message\":");
    json_str(&out, d.msg.as_str());
    out.push(',');
    if (!same_span(d.span, NO_SPAN)) {
        json_place(&out, files, d.span);
        out.push(',');
    }
    out.append("\"labels\":[");
    for (i) in 0..d.labels.len {
        if (i > 0) {
            out.push(',');
        }
        out.push('{');
        json_place(&out, files, d.labels.at(i).span);
        out.append(",\"message\":");
        json_str(&out, d.labels.at(i).msg.as_str());
        out.push('}');
    }
    out.append("],\"notes\":[");
    for (i) in 0..d.notes.len {
        if (i > 0) {
            out.push(',');
        }
        json_str(&out, d.notes.at(i).as_str());
    }
    out.append("]}");
    return move out;
}

fn render_diag(files: std::vec<source_file>&, d: diag&, format: u8, color: bool) -> std::string {
    if (format == FORMAT_JSON) {
        return render_json(files, d);
    }
    if (format == FORMAT_SHORT) {
        var s: std::string = {};
        if (!same_span(d.span, NO_SPAN)) {
            s.append(span_loc(files, d.span).as_str());
            s.append(": ");
        }
        s.append(kind_of_diag(d));
        s.append(": ");
        s.append(d.msg.as_str());
        return move s;
    }
    return render_human(files, d, color);
}

// every diagnostic of a run, in order, up to `limit` errors (0: no limit), then (human format,
// several errors) how many there were
fn report(files: std::vec<source_file>&, diags: std::vec<diag>&, format: u8, color: bool, limit: usize) -> std::string {
    var out: std::string = {};
    var errors: usize = 0;
    var shown: usize = 0;
    for (d&) in diags.items() {
        if (!d.warning) {
            errors += 1;
            if (limit > 0 && shown == limit) {
                continue;
            }
            shown += 1;
        }
        if (out.len() > 0 && format == FORMAT_HUMAN) {
            out.push('\n');
        }
        out.append(render_diag(files, d, format, color).as_str());
        out.push('\n');
    }
    if (errors > 1 && format == FORMAT_HUMAN) {
        out.push('\n');
        paint(&out, color, RED, "error");
        var rest = S(": aborting due to ");
        rest.append_uint(@cast<u64>(errors));
        rest.append(" errors");
        if (shown < errors) {
            rest.append(" (");
            rest.append_uint(@cast<u64>(shown));
            rest.append(" shown; --error-limit 0 shows every one)");
        }
        paint(&out, color, BOLD, rest.as_str());
        out.push('\n');
    }
    return move out;
}

// `: msg` in bold; a type mismatch's message (expected A, found B / mismatched types A and B) has
// the parts where A and B differ in yellow
fn diff_msg(out: std::string&, msg: str) -> void {
    var head = "expected ";
    var mid = ", found ";
    var at = find_from(msg, head, mid);
    if (at == null) {
        head = "mismatched types ";
        mid = " and ";
        at = find_from(msg, head, mid);
    }
    if (at == null) {
        var all = S(": ");
        all.append(msg);
        paint(out, true, BOLD, all.as_str());
        return;
    }
    val i = at ?? 0;
    val a = msg[head.len..i];
    val b = msg[i + mid.len..msg.len];
    val ends = common_ends(a, b);
    out.append(BOLD);
    out.append(": ");
    out.append(head);
    mark_diff(out, a, ends.0, ends.1);
    out.append(mid);
    mark_diff(out, b, ends.0, ends.1);
    out.append(RESET);
}

// where mid first appears in msg after its prefix head (null: msg doesn't start with head, or
// has no mid)
fn find_from(msg: str, head: str, mid: str) -> usize? {
    if (!starts_with(msg, head)) {
        return null;
    }
    var i = head.len;
    while (i + mid.len <= msg.len) {
        if (msg[i..i + mid.len] == mid) {
            return i;
        }
        i += 1;
    }
    return null;
}

// t with its middle (between pre bytes and suf bytes) in yellow, back to bold after
fn mark_diff(out: std::string&, t: str, pre: usize, suf: usize) -> void {
    if (pre + suf == t.len) {
        out.append(t);
        return;
    }
    out.append(t[0..pre]);
    out.append(YELLOW);
    out.append(t[pre..t.len - suf]);
    out.append(RESET);
    out.append(BOLD);
    out.append(t[t.len - suf..t.len]);
}

// how many leading and trailing bytes a and b share, cut back to whole names: i32 against i64
// differs in all of i32, not just in 32
fn common_ends(a: str, b: str) -> (usize, usize) {
    var pre: usize = 0;
    while (pre < a.len && pre < b.len && a[pre] == b[pre]) {
        pre += 1;
    }
    while (pre > 0 && is_word_byte(a[pre - 1]) && ((pre < a.len && is_word_byte(a[pre])) || (pre < b.len && is_word_byte(b[pre])))) {
        pre -= 1;
    }
    var most = a.len - pre;
    if (b.len - pre < most) {
        most = b.len - pre;
    }
    var suf: usize = 0;
    while (suf < most && a[a.len - 1 - suf] == b[b.len - 1 - suf]) {
        suf += 1;
    }
    while (suf > 0 && is_word_byte(a[a.len - suf]) && ((a.len > suf && is_word_byte(a[a.len - suf - 1])) || (b.len > suf && is_word_byte(b[b.len - suf - 1])))) {
        suf -= 1;
    }
    // and never inside a UTF-8 character (a C header's name may have one)
    while (pre > 0 && (utf8_inside(a, pre) || utf8_inside(b, pre))) {
        pre -= 1;
    }
    while (suf > 0 && (utf8_inside(a, a.len - suf) || utf8_inside(b, b.len - suf))) {
        suf -= 1;
    }
    return (pre, suf);
}

// is byte i of s a UTF-8 continuation byte (so i splits a character)?
fn utf8_inside(s: str, i: usize) -> bool {
    return i < s.len && (s[i] & 0xC0) == 0x80;
}

// ---------- building diagnostics ----------

// a compile_error marked as a type mismatch (its message is `expected A, found B` or
// `mismatched types A and B`)
fn type_diff(e: compile_error) -> compile_error {
    var r = move e;
    match (r) {
        .AT(d&) => { d.diff = true; },
    }
    return move r;
}

// a compile_error with a secondary span labelled msg
fn with_label(e: compile_error, sp: span, msg: std::string) -> compile_error {
    var r = move e;
    match (r) {
        .AT(d&) => { put(&d.labels, { span: sp, msg: move msg }); },
    }
    return move r;
}

// a compile_error with a `help: msg` line
fn with_help(e: compile_error, msg: std::string) -> compile_error {
    var r = move e;
    match (r) {
        .AT(d&) => {
            var line = S("help: ");
            line.append(msg.as_str());
            put(&d.notes, move line);
        },
    }
    return move r;
}
