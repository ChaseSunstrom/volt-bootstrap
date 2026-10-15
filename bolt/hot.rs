//! bolt hot: where a program spends its time. It builds with voltc --profiler (line info, frame
//! pointers, and a sampler in the runtime that records the interrupted address and the stack above it
//! about a thousand times a second of CPU time), runs the program, then names the samples with
//! llvm-symbolizer (or addr2line) and the build's .voltmap (C symbols to Volt names): the hottest
//! functions by self and total time, the hottest .volt lines, and the hottest call paths. No perf,
//! ptrace or root needed.
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// one frame of a symbolized address: the function (a Volt name when the .voltmap has it), and the
/// .volt file and line when the code came from Volt
#[derive(Clone)]
struct Frame {
    func: String,
    loc: Option<(String, u32)>,
}

/// an executable mapping of the sampled process: [start, end), its file offset, and the file
struct Map {
    start: u64,
    end: u64,
    offset: u64,
    path: String,
}

/// a VOLT_PROFILE_OUT file: the samples (each the stack, its interrupted address first) and the
/// process's executable mappings
pub struct Profile {
    pub samples: Vec<Vec<u64>>,
    maps: Vec<Map>,
}

pub fn read_profile(path: &Path) -> Result<Profile, String> {
    let d = std::fs::read(path).map_err(|e| format!("can't read {}: {e}", path.display()))?;
    let samples = read_samples(&d).ok_or_else(|| format!("{} isn't a bolt hot profile", path.display()))?;
    // after the samples: "MAPS", a length, /proc/self/maps
    let at = 24 + 8 * u64::from_le_bytes(d[16..24].try_into().unwrap()) as usize;
    let mut maps = Vec::new();
    if d.len() >= at + 16 && &d[at..at + 4] == b"MAPS" {
        let len = u64::from_le_bytes(d[at + 8..at + 16].try_into().unwrap()) as usize;
        let text = String::from_utf8_lossy(&d[at + 16..(at + 16 + len).min(d.len())]).into_owned();
        // start-end perms offset dev inode path
        for l in text.lines() {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 6 || !f[1].contains('x') || !f[5].starts_with('/') {
                continue;
            }
            let Some((s, e)) = f[0].split_once('-') else { continue };
            let hex = |x: &str| u64::from_str_radix(x, 16).ok();
            if let (Some(start), Some(end), Some(offset)) = (hex(s), hex(e), hex(f[2])) {
                maps.push(Map { start, end, offset, path: f[5..].join(" ") });
            }
        }
    }
    Ok(Profile { samples, maps })
}

fn read_samples(d: &[u8]) -> Option<Vec<Vec<u64>>> {
    if d.len() < 24 || &d[..8] != b"VPROF001" {
        return None;
    }
    let word = |i: usize| u64::from_le_bytes(d[i * 8..i * 8 + 8].try_into().unwrap());
    let words = (word(2) as usize).min(d.len() / 8 - 3);
    let mut out = Vec::new();
    let mut i = 0;
    while i < words {
        let n = word(3 + i) as usize;
        if n == 0 || i + 1 + n > words {
            break;
        }
        out.push((0..n).map(|k| word(3 + i + 1 + k)).collect());
        i += 1 + n;
    }
    Some(out)
}

/// exe.voltmap: C symbol -> what it is in Volt ("pipeline<...> (main.volt:6)")
fn read_voltmap(exe: &Path) -> HashMap<String, String> {
    let mut p = exe.as_os_str().to_owned();
    p.push(".voltmap");
    std::fs::read_to_string(PathBuf::from(p))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('\t').map(|(s, v)| (s.to_string(), v.to_string())))
        .collect()
}

/// each address's frames, innermost (inlined) first: the executable's, and a shared library's (libc's
/// memset) by its own file, the address made relative to where it was mapped
fn symbolize_all(exe: &Path, maps: &[Map], addrs: &[u64]) -> Result<HashMap<u64, Vec<Frame>>, String> {
    let exe_path = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
    // a position-independent executable (ELF type 3) is named by its own addresses, like a library; a
    // fixed one (type 2) by where it ran
    let pie = std::fs::read(&exe_path).ok().is_some_and(|b| b.len() > 17 && b[16] == 3 && b[17] == 0);
    let mut by_lib: HashMap<&str, Vec<(u64, u64)>> = HashMap::new();
    let mut own = Vec::new();
    for &a in addrs {
        match maps.iter().find(|m| a >= m.start && a < m.end) {
            Some(m) if Path::new(&m.path) == exe_path => own.push((a, if pie { a - m.start + m.offset } else { a })),
            Some(m) => by_lib.entry(&m.path).or_default().push((a, a - m.start + m.offset)),
            None => own.push((a, a)),
        }
    }
    let rel: Vec<u64> = own.iter().map(|p| p.1).collect();
    let named = symbolize(exe, &rel)?;
    let mut out: HashMap<u64, Vec<Frame>> = own.iter().map(|(a, r)| (*a, named.get(r).cloned().unwrap_or_default())).collect();
    for (lib, pairs) in by_lib {
        let rel: Vec<u64> = pairs.iter().map(|p| p.1).collect();
        let named = symbolize(Path::new(lib), &rel)?;
        let base = Path::new(lib).file_name().map_or(lib.to_string(), |f| f.to_string_lossy().into_owned());
        for (a, r) in pairs {
            let mut frames = named.get(&r).cloned().unwrap_or_default();
            for f in &mut frames {
                // a library's own internal functions have no names left (stripped): say whose they are
                f.func = if f.func == "??" { format!("[{base}]") } else { format!("{} ({base})", f.func) };
            }
            if frames.is_empty() {
                frames.push(Frame { func: format!("[{base}]"), loc: None });
            }
            out.insert(a, frames);
        }
    }
    Ok(out)
}

fn symbolize(exe: &Path, addrs: &[u64]) -> Result<HashMap<u64, Vec<Frame>>, String> {
    let input: String = addrs.iter().map(|a| format!("0x{a:x}\n")).collect();
    let run = |cmd: &mut Command, input: &str| -> Option<String> {
        let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
        let mut stdin = child.stdin.take()?;
        let text = input.to_string();
        let writer = std::thread::spawn(move || std::io::Write::write_all(&mut stdin, text.as_bytes()));
        let out = child.wait_with_output().ok()?;
        writer.join().ok()?.ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let parse_loc = |s: &str| -> Option<(String, u32)> {
        // file:line or file:line:col; ?? when unknown
        let mut parts = s.rsplitn(3, ':').collect::<Vec<_>>();
        parts.reverse();
        let (file, line) = match parts.as_slice() {
            [f, l, c] if c.chars().all(|c| c.is_ascii_digit()) => (f.to_string(), l.parse().ok()?),
            [f, l, _] => (format!("{f}:{l}"), 0),
            [f, l] => (f.to_string(), l.parse().ok()?),
            _ => return None,
        };
        (line > 0 && !file.starts_with("??")).then_some((file, line))
    };
    let mut out = HashMap::new();
    // llvm-symbolizer: per address, (function, file:line:col) for each inlined frame, then a blank line
    if let Some(text) = run(Command::new("llvm-symbolizer").arg(format!("--obj={}", exe.display())).arg("--functions=linkage"), &input) {
        let mut blocks = text.split("\n\n");
        for a in addrs {
            let lines: Vec<&str> = blocks.next().unwrap_or("").lines().collect();
            let frames = lines.chunks(2).map(|c| Frame { func: c[0].to_string(), loc: c.get(1).and_then(|l| parse_loc(l)) }).collect();
            out.insert(*a, frames);
        }
        return Ok(out);
    }
    // addr2line -a: each address's own line (0x and 16 digits), then its (function, location) pairs
    let text = run(Command::new("addr2line").args(["-a", "-f", "-i", "-e"]).arg(exe), &input).ok_or("bolt hot needs llvm-symbolizer or addr2line to name the samples")?;
    let mut cur: Option<u64> = None;
    let mut pending: Option<String> = None;
    for l in text.lines() {
        let as_addr = l.strip_prefix("0x").filter(|h| h.len() == 16).and_then(|h| u64::from_str_radix(h, 16).ok());
        match (as_addr, pending.take()) {
            (Some(a), None) if addrs.contains(&a) => {
                cur = Some(a);
                out.insert(a, Vec::new());
            }
            (_, Some(func)) => {
                if let Some(a) = cur {
                    out.entry(a).or_default().push(Frame { func, loc: parse_loc(l) });
                }
            }
            (_, None) => pending = Some(l.to_string()),
        }
    }
    Ok(out)
}

/// what a report line calls a frame's function: its Volt name (its place relative to here), else the
/// symbol (libc's, say)
fn label(f: &Frame, names: &HashMap<String, String>) -> String {
    // a C compiler's copies of a function (v_work.constprop.0, .isra.0, .part.0, .cold) are that function
    let l = names.get(&f.func).or_else(|| f.func.split_once('.').and_then(|(base, _)| names.get(base))).cloned().unwrap_or_else(|| f.func.clone());
    match std::env::current_dir() {
        Ok(d) => l.replace(&format!("({}/", d.display()), "("),
        Err(_) => l,
    }
}

/// a label for call paths: without its "(file:line)", except a closure's, which is only told apart by
/// where it is (closure@main.volt:30:20)
fn short(l: &str) -> String {
    match l.rsplit_once(" (") {
        Some((a, at)) if a.starts_with("a closure") => {
            let at = at.trim_end_matches(')');
            format!("closure@{}", at.rsplit('/').next().unwrap_or(at))
        }
        Some((a, _)) => a.to_string(),
        None => l.to_string(),
    }
}

fn pct(n: usize, of: usize) -> f64 {
    100.0 * n as f64 / of.max(1) as f64
}

/// the source line, trimmed, for the report
fn source_line(file: &str, line: u32, cache: &mut HashMap<String, Vec<String>>) -> String {
    let lines = cache.entry(file.to_string()).or_insert_with(|| std::fs::read_to_string(file).unwrap_or_default().lines().map(str::to_string).collect());
    let t = lines.get(line as usize - 1).map_or("", |l| l.trim());
    if t.chars().count() > 70 { format!("{}...", t.chars().take(67).collect::<String>()) } else { t.to_string() }
}

/// a profile by Volt name: samples per function (self: innermost; total: anywhere in the stack), per
/// .volt line, and per call path from main down; `outlined`: functions some sample found out of line
#[derive(Default)]
pub struct Stats {
    n: usize,
    outlined: HashSet<String>,
    self_n: HashMap<String, usize>,
    total_n: HashMap<String, usize>,
    lines: HashMap<(String, u32), usize>,
    paths: HashMap<Vec<String>, usize>,
}

/// name a profile of exe's samples (stats for the text and HTML reports)
pub fn analyze(exe: &Path, prof: &Profile) -> Result<Stats, String> {
    let samples = &prof.samples;
    if samples.is_empty() {
        return Ok(Stats::default());
    }
    // a return address is just past its call: the call's own line is one byte back
    let mut addrs: Vec<u64> = samples.iter().flat_map(|s| s.iter().enumerate().map(|(i, a)| if i == 0 { *a } else { a - 1 })).collect();
    addrs.sort_unstable();
    addrs.dedup();
    let syms = symbolize_all(exe, &prof.maps, &addrs)?;
    let names = read_voltmap(exe);
    // an address's last frame is the function its code is in; the ones before it were inlined there.
    // A function no sample found out of line is marked inlined, so its self time isn't read as call
    // overhead
    let outlined: HashSet<String> = syms.values().filter_map(|fs| fs.last()).map(|f| label(f, &names)).collect();
    let none = Vec::new();
    let mut self_n: HashMap<String, usize> = HashMap::new();
    let mut total_n: HashMap<String, usize> = HashMap::new();
    let mut lines: HashMap<(String, u32), usize> = HashMap::new();
    let mut paths: HashMap<Vec<String>, usize> = HashMap::new();
    for s in samples {
        // the whole stack, innermost first, inlined frames included
        let frames: Vec<&Frame> = s.iter().enumerate().flat_map(|(i, a)| syms.get(&if i == 0 { *a } else { a - 1 }).unwrap_or(&none).iter()).collect();
        let mut labels: Vec<String> = frames.iter().map(|f| label(f, &names)).collect();
        // nothing above the program's own main (the C entry point, libc's start-up)
        let volt_main = frames.iter().rposition(|f| f.func == "v_main").or_else(|| frames.iter().rposition(|f| f.func == "main"));
        if let Some(m) = volt_main {
            labels.truncate(m + 1);
        }
        if let Some(l) = labels.first() {
            *self_n.entry(l.clone()).or_default() += 1;
        }
        let mut seen: Vec<&String> = Vec::new();
        for l in &labels {
            if !seen.contains(&l) {
                seen.push(l);
                *total_n.entry(l.clone()).or_default() += 1;
            }
        }
        // the innermost Volt line: time in libc's memset counts where Volt called it
        if let Some((file, line)) = frames.iter().find_map(|f| f.loc.as_ref().filter(|(file, _)| file.ends_with(".volt"))) {
            *lines.entry((file.clone(), *line)).or_default() += 1;
        }
        // from the program's main down; recursion folded (make -> make -> make is make, recursive)
        let mut path: Vec<String> = Vec::new();
        for l in labels.iter().rev().map(|l| short(l)) {
            let l = l.trim_end_matches(" (recursive)").to_string();
            if let Some(j) = path.iter().position(|p| p.trim_end_matches(" (recursive)") == l) {
                path.truncate(j);
                path.push(format!("{l} (recursive)"));
            } else {
                path.push(l);
            }
        }
        *paths.entry(path).or_default() += 1;
    }
    Ok(Stats { n: samples.len(), outlined, self_n, total_n, lines, paths })
}

/// a count map, most first (ties by key)
fn sorted<K: Clone + Ord>(m: &HashMap<K, usize>) -> Vec<(K, usize)> {
    let mut v: Vec<(K, usize)> = m.iter().map(|(k, n)| (k.clone(), *n)).collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    v
}

/// a .volt file as the reports show it: relative to here when it's under here
fn shown(file: &str) -> String {
    Path::new(file).strip_prefix(std::env::current_dir().unwrap_or_default()).map_or(file.to_string(), |p| p.display().to_string())
}

/// the text report for a profile of exe
pub fn report(exe: &Path, s: &Stats, top: usize) -> String {
    let n = s.n;
    if n == 0 {
        return "bolt hot: no samples (the program ran for less than about a millisecond of CPU time)\n".into();
    }
    let mut out = format!("bolt hot: {n} samples of {}\n\n", exe.display());
    out += "  self   total  function\n";
    for (l, k) in sorted(&s.self_n).into_iter().take(top) {
        let inlined = if s.outlined.contains(&l) { "" } else { ", inlined" };
        out += &format!("{:5.1}%  {:5.1}%  {l}{inlined}\n", pct(k, n), pct(s.total_n[&l], n));
    }
    // functions that are only ever callers (main, a pipeline whose closures got inlined into it)
    let callers: Vec<(String, usize)> = sorted(&s.total_n).into_iter().filter(|(l, _)| !s.self_n.contains_key(l)).take(3).collect();
    for (l, k) in callers {
        out += &format!("{:5.1}%  {:5.1}%  {l}\n", 0.0, pct(k, n));
    }
    out += "\nhottest lines\n";
    let mut cache = HashMap::new();
    for ((file, line), k) in sorted(&s.lines).into_iter().take(top) {
        out += &format!("{:5.1}%  {}:{line}  {}\n", pct(k, n), shown(&file), source_line(&file, line, &mut cache));
    }
    out += "\nhottest paths\n";
    for (p, k) in sorted(&s.paths).into_iter().take(top.min(5)) {
        out += &format!("{:5.1}%  {}\n", pct(k, n), p.join(" -> "));
    }
    out
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

/// the call tree of the paths: a node's samples (total), those that stopped there (own), its callees
#[derive(Default)]
struct Node {
    total: usize,
    own: usize,
    kids: HashMap<String, Node>,
}

/// one icicle box and those under it: as wide as its share of its caller's samples, its callees in a
/// row beneath it, widest first. Its title (on hover) says the path, total and self time. Callees
/// under 0.1% of all samples fold into one "other" box, which keeps the page small: boxes at one depth
/// have disjoint samples, so there are at most about a thousand at each
fn icicle(name: &str, node: &Node, parent: usize, path: &str, n: usize, out: &mut String) {
    // a warm colour, the same for a function wherever it shows
    let hue = name.bytes().fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(b as u32)) % 50;
    *out += &format!(
        "<div class=\"n\" data-w=\"{w:.4}%\" style=\"width:{w:.4}%\"><div class=\"l\" style=\"background:hsl({hue},85%,62%)\" title=\"{t}&#10;total {:.1}% ({} samples), self {:.1}%\">{}</div><div class=\"c\">",
        pct(node.total, n),
        node.total,
        pct(node.own, n),
        esc(name),
        w = pct(node.total, parent),
        t = esc(if path.is_empty() { name } else { path }),
    );
    let mut kids: Vec<(&String, &Node)> = node.kids.iter().collect();
    kids.sort_by(|a, b| b.1.total.cmp(&a.1.total).then(a.0.cmp(b.0)));
    let (mut other, mut folded) = (Node::default(), 0);
    for (k, kid) in kids {
        if kid.total * 1000 < n {
            other.total += kid.total;
            other.own += kid.total;
            folded += 1;
            continue;
        }
        let p = if path.is_empty() { k.clone() } else { format!("{path} → {k}") };
        icicle(k, kid, node.total, &p, n, out);
    }
    if folded > 0 {
        let k = format!("other ({folded})");
        let p = if path.is_empty() { k.clone() } else { format!("{path} → {k}") };
        icicle(&k, &other, node.total, &p, n, out);
    }
    *out += "</div></div>";
}

const PAGE_HEAD: &str = r#"<!doctype html>
<html><head><meta charset="utf-8"><title>bolt hot</title>
<style>
body{font:14px system-ui,sans-serif;margin:1.5em;color:#222}
h1{font-size:1.2em}h2{font-size:1.05em;margin-top:1.8em}
#ice{border:1px solid #ccc;overflow:hidden}
.n{box-sizing:border-box;min-width:0;overflow:hidden}
.l{font:12px monospace;height:18px;line-height:18px;padding:0 3px;border:1px solid #fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
.c{display:flex}
table{border-collapse:collapse}td,th{padding:2px 10px;text-align:left}th{cursor:pointer;background:#eee}
td.p{text-align:right;font-variant-numeric:tabular-nums}tr:nth-child(even){background:#f7f7f7}
code{white-space:pre}
</style></head><body>
"#;

const PAGE_SCRIPT: &str = r#"<script>
// click a box: it fills the width, its callers above it, its callees beneath; click the top to go back
function reset(){document.querySelectorAll('#ice .n').forEach(n=>{n.style.display='';n.style.width=n.dataset.w})}
function zoom(n){reset();for(let c=n;c.parentElement.classList.contains('c');c=c.parentElement.parentElement){for(const s of c.parentElement.children)if(s!==c)s.style.display='none';c.style.width='100%'}}
document.querySelectorAll('#ice .l').forEach(l=>l.onclick=()=>zoom(l.parentElement));
// click a column to sort by it (numbers most first, names A to Z); click it again to reverse
document.querySelectorAll('table.s th').forEach((h,i)=>h.onclick=()=>{const d=h.dataset.d=h.dataset.d==='1'?'-1':'1';const b=h.closest('table').tBodies[0];[...b.rows].sort((x,y)=>{const p=x.cells[i],q=y.cells[i];return d*(p.dataset.v?q.dataset.v-p.dataset.v:p.textContent.localeCompare(q.textContent))}).forEach(r=>b.appendChild(r))});
</script></body></html>
"#;

/// the HTML report for a profile of exe: one page that loads nothing from elsewhere. An icicle of
/// the call tree (a callee beneath its caller, as wide as its share of the samples), each function's
/// self and total time, and the `top` hottest lines
pub fn html(exe: &Path, s: &Stats, top: usize) -> String {
    let n = s.n;
    let mut out = PAGE_HEAD.to_string();
    out += &format!("<h1>bolt hot: {n} samples of {}</h1>\n", esc(&exe.display().to_string()));
    if n == 0 {
        return out + "<p>No samples (the program ran for less than about a millisecond of CPU time).</p></body></html>\n";
    }
    let mut root = Node::default();
    for (p, k) in &s.paths {
        root.total += k;
        let mut at = &mut root;
        for f in p {
            at = at.kids.entry(f.clone()).or_default();
            at.total += k;
        }
        at.own += k;
    }
    out += "<h2>call tree</h2>\n<p>Each box is a function beneath the one that called it, as wide as its share of the samples. Hover for its time; click to zoom in, click the top to zoom out.</p>\n<div id=\"ice\">";
    icicle("all", &root, n, "", n, &mut out);
    out += "</div>\n<h2>functions</h2>\n<p><b>self</b>: samples in the function itself (with what's inlined into it); <b>total</b>: with what it calls too. Click a column to sort.</p>\n";
    out += "<table class=\"s\"><thead><tr><th>function</th><th>self</th><th>total</th></tr></thead><tbody>\n";
    for (l, k) in sorted(&s.total_n) {
        let own = s.self_n.get(&l).copied().unwrap_or(0);
        let inlined = if own > 0 && !s.outlined.contains(&l) { " <i>inlined</i>" } else { "" };
        out += &format!("<tr><td>{}{inlined}</td><td class=\"p\" data-v=\"{own}\">{:.1}%</td><td class=\"p\" data-v=\"{k}\">{:.1}%</td></tr>\n", esc(&l), pct(own, n), pct(k, n));
    }
    out += "</tbody></table>\n<h2>hottest lines</h2>\n<table class=\"s\"><thead><tr><th>line</th><th>samples</th><th>source</th></tr></thead><tbody>\n";
    let mut cache = HashMap::new();
    for ((file, line), k) in sorted(&s.lines).into_iter().take(top) {
        out += &format!("<tr><td>{}:{line}</td><td class=\"p\" data-v=\"{k}\">{:.1}%</td><td><code>{}</code></td></tr>\n", esc(&shown(&file)), pct(k, n), esc(&source_line(&file, line, &mut cache)));
    }
    out + "</tbody></table>\n" + PAGE_SCRIPT
}

/// the call paths as folded stacks (flamegraph.pl, speedscope, inferno): one line per path,
/// `main;work;mix 812`
pub fn folded(s: &Stats) -> String {
    sorted(&s.paths).into_iter().map(|(p, k)| format!("{} {k}\n", p.join(";"))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_report() {
        let mut s = Stats { n: 10, ..Default::default() };
        s.paths.insert(vec!["main".into(), "work".into()], 8);
        s.paths.insert(vec!["main".into(), "a<b> & c".into()], 2);
        s.self_n.extend([("work (w.volt:3)".to_string(), 8), ("a<b> & c (w.volt:9)".to_string(), 2)]);
        s.total_n.extend([("work (w.volt:3)".to_string(), 8), ("a<b> & c (w.volt:9)".to_string(), 2), ("main (w.volt:1)".to_string(), 10)]);
        s.outlined.insert("work (w.volt:3)".into());
        let h = html(Path::new("/x/w"), &s, 10);
        assert!(!h.contains("http://") && !h.contains("https://"), "{h}");
        assert!(h.contains("title=\"main → work&#10;total 80.0% (8 samples), self 80.0%\">work</div>"), "{h}");
        assert!(h.contains("title=\"main&#10;total 100.0% (10 samples), self 0.0%\">main</div>"), "{h}");
        // a callee is as wide as its share of its caller
        assert!(h.contains("style=\"width:80.0000%\"><div class=\"l\"") && h.contains(">a&lt;b&gt; &amp; c</div>"), "{h}");
        assert!(h.contains("<th>self</th><th>total</th>") && h.contains("<td>work (w.volt:3)</td><td class=\"p\" data-v=\"8\">80.0%</td><td class=\"p\" data-v=\"8\">80.0%</td></tr>"), "{h}");
        assert!(h.contains("<td>a&lt;b&gt; &amp; c (w.volt:9) <i>inlined</i></td><td class=\"p\" data-v=\"2\">20.0%</td>"), "{h}");
        assert!(h.contains("<td>main (w.volt:1)</td><td class=\"p\" data-v=\"0\">0.0%</td>"), "{h}");
        assert!(html(Path::new("/x/w"), &Stats::default(), 10).contains("No samples"));
        assert_eq!(esc("it's"), "it&#39;s");
    }

    #[test]
    fn html_folds_tiny_paths() {
        // 5000 samples: one hot path, and 3000 callees of main with one sample each (0.02%)
        let mut s = Stats { n: 5000, ..Default::default() };
        s.paths.insert(vec!["main".into(), "hot".into()], 2000);
        for i in 0..3000 {
            s.paths.insert(vec!["main".into(), format!("f{i}")], 1);
        }
        let h = html(Path::new("/x/w"), &s, 10);
        assert!(h.contains(">hot</div>") && !h.contains(">f17</div>"), "{h}");
        assert!(h.contains("title=\"main → other (3000)&#10;total 60.0% (3000 samples), self 60.0%\">other (3000)</div>"), "{h}");
        assert!(h.len() < 10_000, "{} bytes", h.len());
    }

    #[test]
    fn folded_stacks() {
        let mut s = Stats { n: 10, ..Default::default() };
        s.paths.insert(vec!["main".into(), "work".into(), "mix".into()], 7);
        s.paths.insert(vec!["main".into(), "a closure@m.volt:3:4".into()], 3);
        assert_eq!(folded(&s), "main;work;mix 7\nmain;a closure@m.volt:3:4 3\n");
    }
}
