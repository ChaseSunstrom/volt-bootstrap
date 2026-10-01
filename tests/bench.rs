//! Volt against C and C++: each program under bench/ is written in all three. They're built for
//! speed: C with clang and gcc -O2, C++ with clang++ -O2, and Volt with --release through both of
//! voltc's backends (C, compiled by clang, and LLVM). Each runs best of BENCH_RUNS (default 3), and
//! every build has to print the same thing. Prints a table and rewrites the one in
//! site/src/content/docs/internals/benchmarks.md, with the machine and toolchain it ran on.
//!
//!     cargo test --release --test bench -- --ignored --nocapture
//!     BENCH_ONLY=nbody,sort BENCH_RUNS=5 cargo test --release --test bench -- --ignored --nocapture
mod common;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// how one build of a program is made, and what it's called in the table
struct Lang {
    name: &'static str,
    file: &'static str,
}

const LANGS: [Lang; 5] = [
    Lang { name: "C (clang)", file: "main.c" },
    Lang { name: "C (gcc)", file: "main.c" },
    Lang { name: "C++ (clang++)", file: "main.cpp" },
    Lang { name: "Volt (C backend)", file: "main.volt" },
    Lang { name: "Volt (LLVM)", file: "main.volt" },
];

/// a command's first line of output ("" if it can't run)
fn first_line(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd).args(args).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).lines().next().unwrap_or("").trim().to_string()).unwrap_or_default()
}

/// the machine and toolchain a run measures, for the page: CPU, memory, OS, compilers
fn machine(runs: usize) -> String {
    let read = |p: &str| std::fs::read_to_string(p).unwrap_or_default();
    let field = |text: &str, key: &str| text.lines().find(|l| l.starts_with(key)).and_then(|l| l.split(':').nth(1)).map(|v| v.trim().to_string());
    let cpuinfo = read("/proc/cpuinfo");
    let cpu = field(&cpuinfo, "model name").unwrap_or_else(|| std::env::consts::ARCH.to_string());
    let cores = field(&cpuinfo, "cpu cores").map(|c| format!("{c} cores, ")).unwrap_or_default();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    let mem_kib: u64 = field(&read("/proc/meminfo"), "MemTotal").and_then(|v| v.split_whitespace().next()?.parse().ok()).unwrap_or(0);
    let os = read("/etc/os-release").lines().find_map(|l| l.strip_prefix("PRETTY_NAME=")).map(|s| s.trim_matches('"').to_string()).unwrap_or_else(|| std::env::consts::OS.to_string());
    let governor = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor");
    let governor = if governor.trim().is_empty() { String::new() } else { format!(", `{}` frequency governor", governor.trim()) };
    let llvm = ["llvm-config", "llvm-config-22"].iter().map(|c| first_line(c, &["--version"])).find(|v| !v.is_empty()).unwrap_or_default();
    format!(
        "Measured {} on:\n\n- **CPU**: {cpu} ({cores}{threads} threads{governor})\n- **Memory**: {:.0} GiB\n- **OS**: {os}, kernel {}\n- **C and C++**: {}; {}\n- **Volt**: voltc --release; its LLVM backend on LLVM {llvm}\n- **Timing**: best of {runs} runs, wall clock\n\n",
        first_line("date", &["+%Y-%m-%d"]),
        mem_kib as f64 / 1048576.0,
        first_line("uname", &["-r"]),
        first_line("clang", &["--version"]),
        first_line("gcc", &["--version"]),
    )
}

fn run(cmd: &mut Command) -> std::process::Output {
    let o = cmd.output().unwrap();
    assert!(o.status.success(), "{cmd:?} failed:\n{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    o
}

#[test]
#[ignore]
fn bench() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let tmp = Path::new(env!("CARGO_TARGET_TMPDIR")).join("bench");
    std::fs::create_dir_all(&tmp).unwrap();
    // a release voltc, built by the bootstrap compiler, for both backends
    let voltc = tmp.join("voltc");
    let mut srcs: Vec<PathBuf> = std::fs::read_dir(root.join("voltc/src")).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "volt")).collect();
    srcs.sort();
    run(Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("build").args(&srcs).arg("--release").args(common::llvm_cc_args()).arg("-o").arg(&voltc));
    let only: Option<Vec<String>> = std::env::var("BENCH_ONLY").ok().map(|s| s.split(',').map(String::from).collect());
    let runs: usize = std::env::var("BENCH_RUNS").ok().and_then(|s| s.parse().ok()).unwrap_or(3);
    let mut programs: Vec<String> = std::fs::read_dir(root.join("bench")).unwrap().map(|e| e.unwrap()).filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().to_string()).collect();
    programs.sort();
    programs.retain(|p| only.as_ref().is_none_or(|o| o.contains(p)));
    let mut rows = Vec::new();
    for prog in &programs {
        let dir = root.join("bench").join(prog);
        let mut times = Vec::new();
        let mut first_out: Option<String> = None;
        for (k, lang) in LANGS.iter().enumerate() {
            let src = dir.join(lang.file);
            let exe = tmp.join(format!("{prog}-{k}"));
            match k {
                0 => run(Command::new("clang").args(["-O2", "-o"]).arg(&exe).arg(&src).arg("-lm")),
                1 => run(Command::new("gcc").args(["-O2", "-o"]).arg(&exe).arg(&src).arg("-lm")),
                2 => run(Command::new("clang++").args(["-O2", "-std=c++20", "-o"]).arg(&exe).arg(&src)),
                3 => run(Command::new(&voltc).arg("build").arg(&src).args(["--release", "--std"]).arg(root.join("std")).arg("-o").arg(&exe).env("CC", "clang")),
                _ => run(Command::new(&voltc).arg("build").arg(&src).args(["--release", "--backend", "llvm", "--std"]).arg(root.join("std")).arg("-o").arg(&exe)),
            };
            let mut best = Duration::MAX;
            for _ in 0..runs {
                let start = Instant::now();
                let o = run(&mut Command::new(&exe));
                best = best.min(start.elapsed());
                let out = String::from_utf8_lossy(&o.stdout).to_string();
                match &first_out {
                    None => first_out = Some(out),
                    Some(want) => assert_eq!(&out, want, "{prog}: {} prints something else", lang.name),
                }
            }
            times.push(best);
        }
        rows.push((prog.clone(), times));
    }
    // the table: seconds, and each one against C (clang)
    let mut table = String::from("| Program |");
    for l in &LANGS {
        table.push_str(&format!(" {} |", l.name));
    }
    table.push_str("\n| --- |");
    for _ in &LANGS {
        table.push_str(" ---: |");
    }
    table.push('\n');
    for (prog, times) in &rows {
        table.push_str(&format!("| {prog} |"));
        for (k, t) in times.iter().enumerate() {
            let secs = t.as_secs_f64();
            if k == 0 {
                table.push_str(&format!(" {secs:.3} s |"));
            } else {
                table.push_str(&format!(" {secs:.3} s ({:.2}x) |", secs / times[0].as_secs_f64()));
            }
        }
        table.push('\n');
    }
    println!("\n{table}");
    // BENCH_MAX_RATIO=1.25: fail when a Volt build takes longer than that against C (clang)
    if let Some(max) = std::env::var("BENCH_MAX_RATIO").ok().and_then(|s| s.parse::<f64>().ok()) {
        for (prog, times) in &rows {
            for k in 3..LANGS.len() {
                let ratio = times[k].as_secs_f64() / times[0].as_secs_f64();
                assert!(ratio <= max, "{prog}: {} takes {ratio:.2}x C's time (more than {max})", LANGS[k].name);
            }
        }
    }
    if only.is_none() {
        let page = root.join("site/src/content/docs/internals/benchmarks.md");
        let text = std::fs::read_to_string(&page).unwrap();
        let (start, end) = ("<!-- bench:start -->\n", "<!-- bench:end -->");
        let (a, b) = (text.find(start).expect("bench:start marker") + start.len(), text.find(end).expect("bench:end marker"));
        std::fs::write(&page, format!("{}{}{table}{}", &text[..a], machine(runs), &text[b..])).unwrap();
    }
}
