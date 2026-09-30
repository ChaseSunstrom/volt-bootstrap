// Source files and diagnostics: what an error or warning says (a message, the span it's about,
// labelled secondary spans, help and note lines) and how it's shown: the human format with the
// source lines underlined, in colour on a terminal, or one line per diagnostic (short) or JSON for
// tools. voltc/src/diag.volt renders the same bytes.

/// a byte range [lo, hi) in source file `file` (an index into SourceMap.files)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct Span {
    pub file: u32,
    pub lo: u32,
    pub hi: u32,
}

impl Span {
    /// no place in the source (an error about the program as a whole): only the message is shown
    pub const NONE: Span = Span { file: u32::MAX, lo: 0, hi: 0 };

    /// the smallest span covering both; keeps self's file, so both must come from the same file
    pub fn to(self, other: Span) -> Span {
        Span { file: self.file, lo: self.lo.min(other.lo), hi: self.hi.max(other.hi) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Severity {
    #[default]
    Error,
    Warning,
}

/// one diagnostic: the message and its span, plus secondary spans with their own text, and
/// `help: ...` / `note: ...` lines shown under the source
#[derive(Debug, Clone, Default)]
pub struct Diag {
    pub severity: Severity,
    pub span: Span,
    pub msg: String,
    pub labels: Vec<(Span, String)>,
    pub notes: Vec<String>,
    pub diff: bool, // a type mismatch (expected A, found B): colour shows where A and B differ
}

impl Diag {
    pub fn new(span: Span, msg: impl Into<String>) -> Diag {
        Diag { span, msg: msg.into(), ..Default::default() }
    }

    /// a secondary span, underlined with its own text (like "declared here")
    pub fn label(mut self, span: Span, msg: impl Into<String>) -> Diag {
        self.labels.push((span, msg.into()));
        self
    }

    pub fn help(mut self, msg: impl Into<String>) -> Diag {
        self.notes.push(format!("help: {}", msg.into()));
        self
    }

    /// marks a type mismatch, whose message is `expected A, found B` or `mismatched types A and B`
    pub fn type_diff(mut self) -> Diag {
        self.diff = true;
        self
    }
}

pub type Res<T> = Result<T, Diag>;

/// shorthand for returning a Diag: `return err(span, "msg")`
pub fn err<T>(span: Span, msg: impl Into<String>) -> Res<T> {
    Err(Diag::new(span, msg))
}

/// how diagnostics are printed (--message-format, --color)
#[derive(Clone, Copy, PartialEq, Eq, Default)]
pub enum Format {
    #[default]
    Human,
    Short,
    Json,
}

/// every loaded source file; Span.file indexes into `files`
#[derive(Default)]
pub struct SourceMap {
    pub files: Vec<(String, String)>, // (name, text)
}

// ANSI styles for the human format
const RED: &str = "\x1b[1;31m";
const YELLOW: &str = "\x1b[1;33m";
const BLUE: &str = "\x1b[1;34m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

/// display width of a line prefix: a tab counts 4 (the human format shows tabs as 4 spaces)
fn width(s: &str) -> usize {
    s.chars().map(|c| if c == '\t' { 4 } else { 1 }).sum()
}

/// a JSON string literal
fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

impl SourceMap {
    /// registers a file and returns its index for use in Span.file
    pub fn add(&mut self, name: &str, text: String) -> u32 {
        self.files.push((name.to_string(), text));
        (self.files.len() - 1) as u32
    }

    /// 1-based line and column of byte offset `at`; the column counts characters (a tab is one)
    pub fn pos(&self, file: u32, at: u32) -> (usize, usize) {
        let text = &self.files[file as usize].1;
        let mut at = (at as usize).min(text.len());
        while !text.is_char_boundary(at) {
            at -= 1;
        }
        let before = &text[..at];
        let line = before.matches('\n').count() + 1;
        let start = before.rfind('\n').map(|i| i + 1).unwrap_or(0);
        (line, text[start..at].chars().count() + 1)
    }

    /// 1-based line and column of span.lo
    pub fn line_col(&self, span: Span) -> (usize, usize) {
        self.pos(span.file, span.lo)
    }

    /// line `n` (1-based) of a file, without its line break
    fn line(&self, file: u32, n: usize) -> &str {
        let l = self.files[file as usize].1.split('\n').nth(n - 1).unwrap_or("");
        l.strip_suffix('\r').unwrap_or(l)
    }

    /// `file:line:col` of a span's start
    pub fn loc(&self, s: Span) -> String {
        let (l, c) = self.line_col(s);
        format!("{}:{l}:{c}", self.files[s.file as usize].0)
    }

    pub fn render(&self, d: &Diag, format: Format, color: bool) -> String {
        match format {
            Format::Human => self.human(d, color),
            Format::Short if d.span == Span::NONE => format!("{}: {}", Self::kind(d), d.msg),
            Format::Short => format!("{}: {}: {}", self.loc(d.span), Self::kind(d), d.msg),
            Format::Json => self.json(d),
        }
    }

    fn kind(d: &Diag) -> &'static str {
        match d.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        }
    }

    /// the source lines a diagnostic points at, each underlined: ^ for the main span, - for labels
    fn human(&self, d: &Diag, color: bool) -> String {
        let paint = |style: &str, s: &str| if color && !s.is_empty() { format!("{style}{s}{RESET}") } else { s.to_string() };
        let main = if d.severity == Severity::Error { RED } else { YELLOW };
        let msg = if d.diff && color { diff_msg(&d.msg) } else { paint(BOLD, &format!(": {}", d.msg)) };
        let mut out = format!("{}{}", paint(main, Self::kind(d)), msg);
        // the main span, then the labels; one block per file, the main span's file first
        let mut marks: Vec<(Span, &str, bool)> = Vec::new();
        if d.span != Span::NONE {
            marks.push((d.span, "", true));
        }
        marks.extend(d.labels.iter().map(|(s, m)| (*s, m.as_str(), false)));
        let mut files: Vec<u32> = Vec::new();
        for (s, _, _) in &marks {
            if !files.contains(&s.file) {
                files.push(s.file);
            }
        }
        // one gutter width for the whole diagnostic, so every block lines up
        let w = marks.iter().map(|(s, _, _)| self.line_col(*s).0.to_string().len()).max().unwrap_or(1);
        let pad = " ".repeat(w + 1);
        let bar = paint(BLUE, "│");
        for (bi, f) in files.iter().enumerate() {
            let first = marks.iter().find(|m| m.0.file == *f).unwrap().0;
            if bi > 0 {
                out.push_str(&format!("\n{pad}{bar}"));
            }
            out.push_str(&format!("\n{pad}{} {}", paint(BLUE, "┌─"), self.loc(first)));
            out.push_str(&format!("\n{pad}{bar}"));
            // (line, start col, end col, is main, text), in line then column order
            let mut rows: Vec<(usize, usize, usize, bool, &str)> = Vec::new();
            for (s, m, primary) in marks.iter().filter(|m| m.0.file == *f) {
                let (line, _) = self.line_col(*s);
                let text = self.line(*f, line);
                let (l0, _) = self.pos(*f, s.lo);
                let line_start = s.lo as usize - self.byte_col(*f, s.lo);
                let start = width(&text[..(s.lo as usize - line_start).min(text.len())]);
                let (l1, _) = self.pos(*f, s.hi);
                let end = if l1 == l0 { width(&text[..(s.hi as usize - line_start).min(text.len())]) } else { width(text) };
                rows.push((line, start, end.max(start + 1), *primary, m));
            }
            rows.sort_by_key(|r| (r.0, r.1));
            let mut last: Option<usize> = None;
            for (line, start, end, primary, m) in &rows {
                if last != Some(*line) {
                    if last.is_some_and(|l| *line > l + 1) {
                        out.push_str(&format!("\n{pad}{}", paint(BLUE, "·")));
                    }
                    let shown = self.line(*f, *line).replace('\t', "    ");
                    out.push_str(&format!("\n{} {bar} {}", paint(BLUE, &format!("{line:>w$}")), shown.trim_end()));
                    last = Some(*line);
                }
                let (style, ch) = if *primary { (main, "^") } else { (BLUE, "-") };
                let label = if m.is_empty() { String::new() } else { format!(" {m}") };
                out.push_str(&format!("\n{pad}{bar} {}{}", " ".repeat(*start), paint(style, &format!("{}{label}", ch.repeat(end - start)))));
            }
        }
        if !d.notes.is_empty() {
            if !marks.is_empty() {
                out.push_str(&format!("\n{pad}{bar}"));
            }
            for n in &d.notes {
                let (kind, rest) = n.split_once(": ").unwrap_or(("note", n));
                out.push_str(&format!("\n{pad}{} {}: {rest}", paint(BLUE, "="), paint(BOLD, kind)));
            }
        }
        out
    }

    /// the byte offset of `at` within its line
    fn byte_col(&self, file: u32, at: u32) -> usize {
        let text = &self.files[file as usize].1;
        let at = (at as usize).min(text.len());
        at - text[..at].rfind('\n').map(|i| i + 1).unwrap_or(0)
    }

    fn json(&self, d: &Diag) -> String {
        let place = |s: Span| {
            let (l0, c0) = self.pos(s.file, s.lo);
            let (l1, c1) = self.pos(s.file, s.hi);
            format!("\"file\":{},\"line\":{l0},\"column\":{c0},\"end_line\":{l1},\"end_column\":{c1}", json_str(&self.files[s.file as usize].0))
        };
        let labels: Vec<String> = d.labels.iter().map(|(s, m)| format!("{{{},\"message\":{}}}", place(*s), json_str(m))).collect();
        let notes: Vec<String> = d.notes.iter().map(|n| json_str(n)).collect();
        let at = if d.span == Span::NONE { String::new() } else { format!("{},", place(d.span)) };
        format!(
            "{{\"severity\":\"{}\",\"message\":{},{at}\"labels\":[{}],\"notes\":[{}]}}",
            Self::kind(d),
            json_str(&d.msg),
            labels.join(","),
            notes.join(",")
        )
    }

    /// every diagnostic of a run, in order, up to `limit` errors (0: no limit), then (human
    /// format, several errors) how many there were
    pub fn report(&self, diags: &[Diag], format: Format, color: bool, limit: usize) -> String {
        let limit = if limit == 0 { usize::MAX } else { limit };
        let mut out = String::new();
        let mut shown = 0;
        for d in diags {
            if d.severity == Severity::Error {
                if shown == limit {
                    continue;
                }
                shown += 1;
            }
            if !out.is_empty() && format == Format::Human {
                out.push('\n');
            }
            out.push_str(&self.render(d, format, color));
            out.push('\n');
        }
        let errors = diags.iter().filter(|d| d.severity == Severity::Error).count();
        let mut rest = format!(": aborting due to {errors} errors");
        if errors > limit {
            rest.push_str(&format!(" ({shown} shown; --error-limit 0 shows every one)"));
        }
        if errors > 1 && format == Format::Human {
            let head = if color { format!("{RED}error{RESET}") } else { "error".into() };
            out.push_str(&format!("\n{head}{}\n", if color { format!("{BOLD}{rest}{RESET}") } else { rest }));
        }
        out
    }
}

/// `: msg` in bold, a type mismatch's message (expected A, found B / mismatched types A and B)
/// with the parts where A and B differ in yellow
fn diff_msg(msg: &str) -> String {
    let parts = [("expected ", ", found "), ("mismatched types ", " and ")].iter().find_map(|(head, mid)| {
        let (a, b) = msg.strip_prefix(head)?.split_once(mid)?;
        Some((*head, a, *mid, b))
    });
    let Some((head, a, mid, b)) = parts else { return format!("{BOLD}: {msg}{RESET}") };
    let (pre, suf) = common_ends(a, b);
    let mark = |t: &str| {
        let (x, y, z) = (&t[..pre], &t[pre..t.len() - suf], &t[t.len() - suf..]);
        if y.is_empty() { t.to_string() } else { format!("{x}{YELLOW}{y}{RESET}{BOLD}{z}") }
    };
    format!("{BOLD}: {head}{}{mid}{}{RESET}", mark(a), mark(b))
}

/// how many leading and trailing bytes a and b share, cut back to whole names: i32 against i64
/// differs in all of i32, not just in 32
fn common_ends(a: &str, b: &str) -> (usize, usize) {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
    let mut pre = x.iter().zip(y).take_while(|(p, q)| p == q).count();
    while pre > 0 && word(x[pre - 1]) && (x.get(pre).is_some_and(|&c| word(c)) || y.get(pre).is_some_and(|&c| word(c))) {
        pre -= 1;
    }
    let most = (x.len() - pre).min(y.len() - pre);
    let mut suf = x.iter().rev().zip(y.iter().rev()).take(most).take_while(|(p, q)| p == q).count();
    let before = |s: &[u8], suf: usize| s.len() > suf && word(s[s.len() - suf - 1]);
    while suf > 0 && word(x[x.len() - suf]) && (before(x, suf) || before(y, suf)) {
        suf -= 1;
    }
    // and never inside a UTF-8 character (a C header's name may have one)
    let inside = |s: &[u8], i: usize| i < s.len() && s[i] & 0xC0 == 0x80;
    while pre > 0 && (inside(x, pre) || inside(y, pre)) {
        pre -= 1;
    }
    while suf > 0 && (inside(x, x.len() - suf) || inside(y, y.len() - suf)) {
        suf -= 1;
    }
    (pre, suf)
}

#[cfg(test)]
mod tests {
    use super::common_ends;

    #[test]
    fn common_ends_cut_at_names_and_characters() {
        let a = "std::vec<i32, alloc>";
        let b = "std::vec<i64, alloc>";
        let (pre, suf) = common_ends(a, b);
        assert_eq!((&a[pre..a.len() - suf], &b[pre..b.len() - suf]), ("i32", "i64"));
        assert_eq!(common_ends("i32*", "i64*"), (0, 1));
        assert_eq!(common_ends("T", "T&"), (1, 0)); // only the & differs
        // é and è share their first byte: the cut can't land inside them
        let (pre, suf) = common_ends("sé", "sè");
        assert!("sé".is_char_boundary(pre) && "sè".is_char_boundary(pre) && pre + suf <= 3);
    }
}
