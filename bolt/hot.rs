//! bolt hot: where a program spends its time. It builds with voltc --profiler (line info, frame
//! pointers, and a sampler in the runtime that records the interrupted address and the stack above it
//! about a thousand times a second of CPU time), runs the program, then names the samples with
//! llvm-symbolizer (or addr2line) and the build's .voltmap (C symbols to Volt names): the hottest
//! functions by self and total time, the hottest .volt lines, and the hottest call paths. No perf,
//! ptrace or root needed.
use std::collections::HashMap;
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
    let l = names.get(&f.func).cloned().unwrap_or_else(|| f.func.clone());
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

/// the report for a profile of exe
pub fn report(exe: &Path, prof: &Profile, top: usize) -> Result<String, String> {
    let samples = &prof.samples;
    if samples.is_empty() {
        return Ok("bolt hot: no samples (the program ran for less than about a millisecond of CPU time)\n".into());
    }
    // a return address is just past its call: the call's own line is one byte back
    let mut addrs: Vec<u64> = samples.iter().flat_map(|s| s.iter().enumerate().map(|(i, a)| if i == 0 { *a } else { a - 1 })).collect();
    addrs.sort_unstable();
    addrs.dedup();
    let syms = symbolize_all(exe, &prof.maps, &addrs)?;
    let names = read_voltmap(exe);
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
    let n = samples.len();
    let sorted = |m: HashMap<String, usize>| {
        let mut v: Vec<(String, usize)> = m.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v
    };
    let mut out = format!("bolt hot: {n} samples of {}\n\n", exe.display());
    out += "  self   total  function\n";
    for (l, k) in sorted(self_n.clone()).into_iter().take(top) {
        out += &format!("{:5.1}%  {:5.1}%  {l}\n", pct(k, n), pct(total_n[&l], n));
    }
    // functions that are only ever callers (main, a pipeline whose closures got inlined into it)
    let callers: Vec<(String, usize)> = sorted(total_n).into_iter().filter(|(l, _)| !self_n.contains_key(l)).take(3).collect();
    for (l, k) in callers {
        out += &format!("{:5.1}%  {:5.1}%  {l}\n", 0.0, pct(k, n));
    }
    out += "\nhottest lines\n";
    let mut lv: Vec<((String, u32), usize)> = lines.into_iter().collect();
    lv.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let mut cache = HashMap::new();
    for ((file, line), k) in lv.into_iter().take(top) {
        let shown = Path::new(&file).strip_prefix(std::env::current_dir().unwrap_or_default()).map_or(file.clone(), |p| p.display().to_string());
        out += &format!("{:5.1}%  {shown}:{line}  {}\n", pct(k, n), source_line(&file, line, &mut cache));
    }
    out += "\nhottest paths\n";
    let mut pv: Vec<(Vec<String>, usize)> = paths.into_iter().collect();
    pv.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    for (p, k) in pv.into_iter().take(top.min(5)) {
        out += &format!("{:5.1}%  {}\n", pct(k, n), p.join(" -> "));
    }
    Ok(out)
}
