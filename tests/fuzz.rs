// Fuzzing, seeded so a failure repeats. checker_survives_mutants: broken variants of the test
// programs (a token deleted, doubled or swapped, lines swapped or dropped, the file cut short) must
// get diagnostics, never a crash or a hang. VOLT_FUZZ=N checks N mutants (default 1500) and
// VOLT_FUZZ_SEED=S starts elsewhere; what fails is saved under target/tmp/fuzz.
mod common;
use std::path::{Path, PathBuf};
use std::process::Command;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// xorshift64*: small, and the same everywhere
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

fn env_num(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// the byte ranges of src's tokens, roughly: words, numbers, strings and single punctuation
fn tokens(src: &str) -> Vec<(usize, usize)> {
    let b = src.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < b.len() {
        let c = b[i];
        let start = i;
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        } else if c.is_ascii_alphanumeric() || c == b'_' {
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
        } else if c == b'"' {
            i += 1;
            while i < b.len() && b[i] != b'"' && b[i] != b'\n' {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            i = (i + 1).min(b.len());
        } else {
            // a whole UTF-8 character
            i += 1;
            while i < b.len() && (b[i] & 0xC0) == 0x80 {
                i += 1;
            }
        }
        out.push((start, i));
    }
    out
}

/// one random change to src
fn mutate(src: &str, rng: &mut Rng) -> String {
    let toks = tokens(src);
    if toks.is_empty() {
        return src.to_string();
    }
    let (s, e) = toks[rng.below(toks.len())];
    match rng.below(6) {
        0 => format!("{}{}", &src[..s], &src[e..]),
        1 => format!("{} {}", &src[..e], &src[s..]),
        2 => {
            let (s2, e2) = toks[rng.below(toks.len())];
            format!("{}{}{}", &src[..s], &src[s2..e2], &src[e..])
        }
        3 => src[..s].to_string(),
        n => {
            let mut lines: Vec<&str> = src.lines().collect();
            let i = rng.below(lines.len());
            if n == 4 && i + 1 < lines.len() {
                lines.swap(i, i + 1);
            } else {
                lines.remove(i);
            }
            lines.join("\n")
        }
    }
}

#[test]
fn checker_survives_mutants() {
    let root = Path::new(ROOT);
    let mut corpus: Vec<(PathBuf, String)> = Vec::new();
    for dir in ["tests/run", "tests/fail", "examples"] {
        for e in std::fs::read_dir(root.join(dir)).unwrap() {
            let p = e.unwrap().path();
            let text = std::fs::read_to_string(&p).unwrap_or_default();
            // C headers (libclang) and other languages are slow to read and not what this is for
            if p.extension().is_some_and(|x| x == "volt") && !text.contains(".h\"") && !text.lines().any(|l| l.starts_with("use ") && l.contains('{')) {
                corpus.push((p, text));
            }
        }
    }
    corpus.sort();
    let n = env_num("VOLT_FUZZ", 1500);
    let seed = env_num("VOLT_FUZZ_SEED", 0x5eed);
    let out = Path::new(env!("CARGO_TARGET_TMPDIR")).join("fuzz");
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(&out).unwrap();
    let voltc = common::voltc();
    let std_dir = root.join("std");
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get()) as u64;
    let bad = std::sync::Mutex::new(Vec::new());
    std::thread::scope(|sc| {
        for t in 0..threads {
            let (corpus, out, voltc, std_dir, bad) = (&corpus, &out, &voltc, &std_dir, &bad);
            sc.spawn(move || {
                for i in (t..n).step_by(threads as usize) {
                    // each mutant has its own seed, so VOLT_FUZZ_SEED and its number repeat it
                    let mut rng = Rng(seed.wrapping_mul(0x9E3779B97F4A7C15) ^ (i + 1));
                    let (from, text) = &corpus[rng.below(corpus.len())];
                    let mut m = text.clone();
                    for _ in 0..1 + rng.below(3) {
                        m = mutate(&m, &mut rng);
                    }
                    let f = out.join(format!("m{i}.volt"));
                    std::fs::write(&f, &m).unwrap();
                    // generous: the two tests run at once, each with a thread per CPU
                    let o = Command::new("timeout").arg("30").arg(voltc).arg("check").arg(&f).arg("--std").arg(std_dir).output().unwrap();
                    match o.status.code() {
                        Some(0) | Some(1) => {
                            let _ = std::fs::remove_file(&f);
                        }
                        code => {
                            let what = if code == Some(124) { "hangs".to_string() } else { format!("exits {code:?}") };
                            let err = String::from_utf8_lossy(&o.stderr);
                            let tail: Vec<&str> = err.lines().rev().take(3).collect();
                            bad.lock().unwrap().push(format!("{} (mutant {i} of {}) {what}: {}", f.display(), from.strip_prefix(ROOT).unwrap_or(from).display(), tail.join(" / ")));
                        }
                    }
                }
            });
        }
    });
    let bad = bad.into_inner().unwrap();
    assert!(bad.is_empty(), "{} of {n} mutants crash or hang voltc check (seed {seed:#x}):\n{}", bad.len(), bad.join("\n"));
}

// ---- backends_agree: random programs that always end, through both backends, debug and release

const TYS: [(&str, u32, bool); 5] = [("u64", 64, false), ("u32", 32, false), ("u8", 8, false), ("i64", 64, true), ("i32", 32, true)];

/// a random program: integer arithmetic that can't trap (wrapping operators, shifts by less than
/// the width, unsigned division by an odd number, masked indexes), calls to earlier functions,
/// bounded loops; it prints a hash of everything it computed
struct Gen {
    rng: Rng,
    out: String,
    vars: Vec<(String, usize)>, // name, index into TYS
    fns: Vec<(String, Vec<usize>, usize)>,
    next: usize,
    in_loop: bool,
}

impl Gen {
    fn name(&mut self, p: &str) -> String {
        self.next += 1;
        format!("{p}{}", self.next)
    }
    /// small ones bare (literals take their type from where they are), big ones typed by a cast
    fn lit(&mut self, t: usize) -> String {
        let (ty, bits, signed) = TYS[t];
        let v = self.rng.next();
        let small = self.rng.below(3) == 0;
        match (signed, small) {
            (_, true) => (v % 17).to_string(),
            (false, _) => format!("@cast<{ty}>({})", if bits == 64 { v } else { v & ((1u64 << bits) - 1) }),
            (true, _) => format!("@cast<{ty}>({})", if bits == 64 { v as i64 } else { (v as i64) >> (64 - bits) }),
        }
    }
    fn expr(&mut self, t: usize, depth: usize) -> String {
        let (ty, bits, signed) = TYS[t];
        let choice = if depth == 0 { self.rng.below(2) } else { self.rng.below(11) };
        match choice {
            0 => {
                let have: Vec<String> = self.vars.iter().filter(|v| v.1 == t).map(|v| v.0.clone()).collect();
                if have.is_empty() { self.lit(t) } else { have[self.rng.below(have.len())].clone() }
            }
            1 => self.lit(t),
            2 | 3 => {
                let op = ["+%", "-%", "*%", "&", "|", "^"][self.rng.below(6)];
                format!("({} {op} {})", self.expr(t, depth - 1), self.expr(t, depth - 1))
            }
            4 if !signed => {
                let op = [">>", "<<"][self.rng.below(2)];
                let by = if self.rng.below(2) == 0 { self.rng.below(bits as usize).to_string() } else { format!("(@cast<u32>({}) & {})", self.expr(t, depth - 1), bits - 1) };
                format!("(@cast<{ty}>({}) {op} {by})", self.expr(t, depth - 1))
            }
            5 if !signed => {
                let op = ["/", "%"][self.rng.below(2)];
                format!("(@cast<{ty}>({}) {op} ({} | 1))", self.expr(t, depth - 1), self.expr(t, depth - 1))
            }
            6 => {
                let from = self.rng.below(TYS.len());
                format!("@cast<{ty}>({})", self.expr(from, depth - 1))
            }
            // the arms cast: a literal arm is i32 before the other arm is seen (T-0264)
            7 => format!("(if ({}) @cast<{ty}>({}) else @cast<{ty}>({}))", self.cond(depth - 1), self.expr(t, depth - 1), self.expr(t, depth - 1)),
            8 if t == 0 => format!("arr[@cast<usize>({} & 7)]", self.expr(0, depth - 1)),
            // no calls in loops, so the work stays small: each function runs its loops a few times
            9 if !self.in_loop => {
                let callable: Vec<(String, Vec<usize>)> = self.fns.iter().filter(|f| f.2 == t).map(|f| (f.0.clone(), f.1.clone())).collect();
                if callable.is_empty() {
                    return self.expr(t, depth - 1);
                }
                let (f, ps) = callable[self.rng.below(callable.len())].clone();
                let args: Vec<String> = ps.iter().map(|&p| self.expr(p, depth - 1)).collect();
                format!("{f}({})", args.join(", "))
            }
            _ => self.expr(t, depth - 1),
        }
    }
    fn cond(&mut self, depth: usize) -> String {
        let t = self.rng.below(TYS.len());
        let op = ["<", "<=", "==", "!=", ">", ">="][self.rng.below(6)];
        let ty = TYS[t].0;
        let c = format!("(@cast<{ty}>({}) {op} @cast<{ty}>({}))", self.expr(t, depth), self.expr(t, depth));
        match self.rng.below(4) {
            0 => format!("({c} && {})", self.cond(depth.saturating_sub(1))),
            1 => format!("(!{c})"),
            _ => c,
        }
    }
    fn line(&mut self, indent: usize, s: &str) {
        self.out.push_str(&"    ".repeat(indent));
        self.out.push_str(s);
        self.out.push('\n');
    }
    fn stmts(&mut self, indent: usize, n: usize) {
        let scope = self.vars.len();
        for _ in 0..n {
            match self.rng.below(if indent > 2 { 4 } else { 7 }) {
                0 | 1 => {
                    let t = self.rng.below(TYS.len());
                    let (v, e) = (self.name("v"), self.expr(t, 3));
                    self.line(indent, &format!("var {v}: {} = {e};", TYS[t].0));
                    self.vars.push((v, t));
                }
                2 => {
                    let t = self.rng.below(TYS.len());
                    let e = self.expr(t, 3);
                    self.line(indent, &format!("h = (h ^ @cast<u64>({e})) *% 1099511628211;"));
                }
                3 => {
                    // only the vars (parameters and loop indexes can't be assigned)
                    let mine: Vec<(String, usize)> = self.vars.iter().filter(|v| v.0.starts_with('v')).cloned().collect();
                    if mine.is_empty() {
                        continue;
                    }
                    let (v, t) = mine[self.rng.below(mine.len())].clone();
                    let e = self.expr(t, 3);
                    self.line(indent, &format!("{v} = {e};"));
                }
                4 => {
                    let c = self.cond(2);
                    self.line(indent, &format!("if {c} {{"));
                    let k = 1 + self.rng.below(3);
                    self.stmts(indent + 1, k);
                    self.line(indent, "} else {");
                    let k = 1 + self.rng.below(3);
                    self.stmts(indent + 1, k);
                    self.line(indent, "}");
                }
                5 => {
                    let i = self.name("i");
                    let n = 1 + self.rng.below(4);
                    self.line(indent, &format!("for ({i}) in 0..{n} {{"));
                    let was = std::mem::replace(&mut self.in_loop, true);
                    self.vars.push((format!("@cast<u64>({i})"), 0));
                    let k = 1 + self.rng.below(3);
                    self.stmts(indent + 1, k);
                    self.vars.pop();
                    self.in_loop = was;
                    self.line(indent, "}");
                }
                _ => {
                    let e = self.expr(0, 3);
                    self.line(indent, &format!("arr[@cast<usize>(h & 7)] = {e};"));
                }
            }
        }
        self.vars.truncate(scope);
    }
    fn program(seed: u64) -> String {
        let mut g = Gen { rng: Rng(seed), out: String::from("use std::io;\n\n"), vars: Vec::new(), fns: Vec::new(), next: 0, in_loop: false };
        for _ in 0..2 + g.rng.below(4) {
            let f = g.name("f");
            let ps: Vec<usize> = (0..1 + g.rng.below(3)).map(|_| g.rng.below(TYS.len())).collect();
            let ret = g.rng.below(TYS.len());
            let params: Vec<String> = ps.iter().enumerate().map(|(i, &p)| format!("p{i}: {}", TYS[p].0)).collect();
            g.line(0, &format!("fn {f}({}) -> {} {{", params.join(", "), TYS[ret].0));
            g.vars = ps.iter().enumerate().map(|(i, &p)| (format!("p{i}"), p)).collect();
            g.line(1, "var h: u64 = 14695981039346656037;");
            g.line(1, "var arr: u64[8] = { 3; 8 };");
            let k = 2 + g.rng.below(4);
            g.stmts(1, k);
            let e = g.expr(ret, 3);
            g.line(1, &format!("return @cast<{}>(h) ^ {e};", TYS[ret].0));
            g.line(0, "}\n");
            g.fns.push((f, ps, ret));
        }
        g.vars.clear();
        g.line(0, "fn main() -> void {");
        g.line(1, "var h: u64 = 14695981039346656037;");
        g.line(1, "var arr: u64[8] = { 5; 8 };");
        let k = 6 + g.rng.below(8);
        g.stmts(1, k);
        g.line(1, "for (x) in arr {");
        g.line(2, "h = (h ^ x) *% 1099511628211;");
        g.line(1, "}");
        g.line(1, "std::println(h);");
        g.line(0, "}");
        g.out
    }
}

#[test]
fn backends_agree() {
    let n = (env_num("VOLT_FUZZ", 1500) / 40).max(1);
    let seed = env_num("VOLT_FUZZ_SEED", 0x5eed);
    let out = Path::new(env!("CARGO_TARGET_TMPDIR")).join("fuzz-backends");
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(&out).unwrap();
    let voltc = common::voltc();
    let std_dir = Path::new(ROOT).join("std");
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get()) as u64;
    let bad = std::sync::Mutex::new(Vec::new());
    std::thread::scope(|sc| {
        for t in 0..threads {
            let (out, voltc, std_dir, bad) = (&out, &voltc, &std_dir, &bad);
            sc.spawn(move || {
                for i in (t..n).step_by(threads as usize) {
                    let src = Gen::program(seed.wrapping_mul(0x9E3779B97F4A7C15) ^ (i + 1));
                    let f = out.join(format!("p{i}.volt"));
                    std::fs::write(&f, &src).unwrap();
                    let mut runs = Vec::new();
                    for (backend, release) in [("c", false), ("llvm", false), ("c", true), ("llvm", true)] {
                        let mut c = Command::new("timeout");
                        c.arg("60").arg(voltc).args(["run"]).arg(&f).arg("--std").arg(std_dir).args(["--backend", backend]);
                        if release {
                            c.arg("--release");
                        }
                        let o = c.output().unwrap();
                        let what = format!("{backend}{}", if release { " --release" } else { "" });
                        let text = if o.status.success() { String::from_utf8_lossy(&o.stdout).trim().to_string() } else { format!("exit {:?}: {}", o.status.code(), String::from_utf8_lossy(&o.stderr).lines().take(3).collect::<Vec<_>>().join(" / ")) };
                        runs.push((what, text));
                    }
                    if runs.iter().any(|r| r.1 != runs[0].1) || runs[0].1.starts_with("exit") {
                        let all: Vec<String> = runs.iter().map(|(w, t)| format!("  {w}: {t}")).collect();
                        bad.lock().unwrap().push(format!("{} (program {i}):\n{}", f.display(), all.join("\n")));
                    } else {
                        let _ = std::fs::remove_file(&f);
                    }
                }
            });
        }
    });
    let bad = bad.into_inner().unwrap();
    assert!(bad.is_empty(), "{} of {n} programs differ between backends or fail (seed {seed:#x}):\n{}", bad.len(), bad.join("\n"));
}
