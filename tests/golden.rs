// Golden tests. tests/run/*.volt and examples/*.volt: compiled and run, stdout must equal the `// expect: ` lines
// (and exit code the `// exit: N` line, default 0, or one of `// exit: N|M`; `// flags: --release` passes flags; each `// expect-stderr: ` line must be
// in stderr, each `// reject-stderr: ` line must not). tests/fail/*.volt: `voltc check` must fail with every `// error: ` substring in its stderr.
// voltc is stage 1: voltc/src built by the bootstrap compiler.
mod common;
use std::path::Path;
use std::process::Command;

/// the text after each `// key:` line of src (one leading space dropped)
fn directives(src: &str, key: &str) -> Vec<String> {
    let tag = format!("// {key}:");
    src.lines()
        .filter_map(|l| l.trim_start().strip_prefix(&tag).map(|r| r.strip_prefix(' ').unwrap_or(r).to_string()))
        .collect()
}

/// the .volt files directly in dir, sorted (none if it doesn't exist)
fn files(dir: &str) -> Vec<std::path::PathBuf> {
    let mut v: Vec<_> = std::fs::read_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join(dir))
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect())
        .unwrap_or_default();
    v.sort();
    v
}

#[test]
fn golden() {
    let bin = common::voltc();
    let mut failures = Vec::new();
    let mut count = 0;
    // programs: run, then compare stdout and the exit code
    for f in files("tests/run").into_iter().chain(files("examples")) {
        count += 1;
        let src = std::fs::read_to_string(&f).unwrap();
        // `// unix-only`: its oracle is Unix's (glibc's or Apple's libm, sh's kill)
        if cfg!(windows) && src.lines().any(|l| l.starts_with("// unix-only")) {
            continue;
        }
        let want = directives(&src, "expect").join("\n");
        // `// exit: 132|133`: any of them (a trap is SIGILL on x86-64, SIGTRAP on arm64)
        let want_codes: Vec<i32> = directives(&src, "exit").first().map(|s| s.split('|').map(|c| c.trim().parse().unwrap()).collect()).unwrap_or(vec![0]);
        let flags: Vec<String> = directives(&src, "flags").iter().flat_map(|l| l.split_whitespace().map(String::from).collect::<Vec<_>>()).collect();
        // a program that hangs (a release build reading out of bounds can) fails instead of stopping the run
        let out = common::run_for(Command::new(&bin).arg("run").arg(&f).args(&flags), 120);
        let got = String::from_utf8_lossy(&out.stdout);
        let code = if out.timed_out { 124 } else { out.code.unwrap_or(-1) };
        // Windows ends a crashed program with an NTSTATUS: the code a signal gives elsewhere
        let code = match code as u32 {
            0xC000001D => 132, // an illegal instruction (a trap): SIGILL
            0x80000003 => 133, // a breakpoint: SIGTRAP
            0xC0000409 => 134, // __fastfail, which abort is: SIGABRT
            0xC0000005 => 139, // an access violation: SIGSEGV
            _ => code,
        };
        let err = String::from_utf8_lossy(&out.stderr);
        let err_missing = directives(&src, "expect-stderr").iter().any(|w| !err.contains(w.as_str()))
            || directives(&src, "reject-stderr").iter().any(|w| err.contains(w.as_str()));
        if got.trim_end() != want.trim_end() || !want_codes.contains(&code) || err_missing {
            failures.push(format!(
                "{}: exit {code} (want {want_codes:?})\n--- want\n{want}\n--- got\n{got}\n--- stderr\n{}",
                f.display(),
                String::from_utf8_lossy(&out.stderr)
            ));
        }
    }
    // programs that must not check: every `// error:` text must be in stderr
    for f in files("tests/fail") {
        count += 1;
        let src = std::fs::read_to_string(&f).unwrap();
        let flags: Vec<String> = directives(&src, "flags").iter().flat_map(|l| l.split_whitespace().map(String::from).collect::<Vec<_>>()).collect();
        let out = Command::new(&bin).arg("check").arg(&f).args(&flags).output().unwrap();
        let stderr = String::from_utf8_lossy(&out.stderr);
        let wants = directives(&src, "error");
        if out.status.success() || wants.is_empty() || wants.iter().any(|w| !stderr.contains(w.as_str())) {
            failures.push(format!("{}: want errors {wants:?}\n--- stderr\n{stderr}", f.display()));
        }
    }
    assert!(failures.is_empty(), "{} of {count} golden tests failed:\n\n{}", failures.len(), failures.join("\n\n"));
}

/// test.volt, the language sketch, parses
#[test]
fn spec_sketch_parses() {
    let out = Command::new(common::voltc()).args(["parse", "test.volt", "--sexp"]).current_dir(env!("CARGO_MANIFEST_DIR")).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

/// programs the LLVM backend can't lower (tests/llvm/c_partial_*.volt: a C struct only C can pass by
/// value, through a C function pointer or a Volt fn handed to C) build through C by default, with a
/// note naming the line, and print what they expect. They live outside tests/run, which bolt's
/// bootstrap step runs with --backend llvm
#[test]
fn llvm_falls_back_to_c() {
    let progs: Vec<_> = files("tests/llvm").into_iter().filter(|f| f.file_name().is_some_and(|n| n.to_string_lossy().starts_with("c_partial_"))).collect();
    assert_eq!(progs.len(), 2, "tests/llvm/c_partial_*.volt");
    for f in progs {
        let src = std::fs::read_to_string(&f).unwrap();
        let out = Command::new(common::voltc()).arg("run").arg(&f).output().unwrap();
        let (got, err) = (String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        let want = directives(&src, "expect").join("\n");
        // on Windows C is the default backend, so there's nothing to fall back from and no note
        let notes = cfg!(windows) || directives(&src, "expect-stderr").iter().all(|w| err.contains(w.as_str()));
        assert!(out.status.success() && got.trim_end() == want.trim_end() && notes, "{}:\n--- want\n{want}\n--- got\n{got}\n--- stderr\n{err}", f.display());
    }
}

/// packages precompiled with `voltc lib` and linked: same output as compiling them from source
#[test]
fn std_linked() {
    let bin = common::voltc();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("linked-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let voltc = |args: &[&str]| Command::new(&bin).args(args).current_dir(root).output().unwrap();
    let lib = |name: &str| dir.join(format!("lib{name}.a")).to_str().unwrap().to_string();
    let (std_a, geo_a, hold_a, geo2_a) = (lib("std"), lib("geo"), lib("hold"), lib("geo2"));
    let pkgs = ["--pkg", "geo=tests/pkgs/geo", "--pkg", "hold=tests/pkgs/hold", "--pkg", "geo2=tests/pkgs/geo2"];
    let hold_link = format!("hold={hold_a}");
    // geo2 uses hold: built against libhold.a, as bolt builds a dependent (a library build keeps
    // its references to hold, whatever hold's globals hold)
    for (pkg, out, more) in [("std", &std_a, &[][..]), ("geo", &geo_a, &[]), ("hold", &hold_a, &[]), ("geo2", &geo2_a, &["--link", hold_link.as_str()])] {
        let o = voltc(&[&["lib", pkg, "-o", out][..], &pkgs, more].concat());
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(o.status.success() && !err.contains("isn't used"), "voltc lib {pkg}: {err}");
    }
    let prog = "tests/run/packages_linked.volt";
    let want = directives(&std::fs::read_to_string(root.join(prog)).unwrap(), "expect").join("\n");
    let std_link = format!("std={std_a}");
    let geo_link = format!("geo={geo_a}");
    let geo2_link = format!("geo2={geo2_a}");
    // hold twice: one warning
    let links = ["--link", &std_link, "--link", &geo_link, "--link", &hold_link, "--link", &hold_link, "--link", &geo2_link];
    let o = voltc(&[&["run", prog, "--leak-check"][..], &links, &pkgs].concat());
    let got = String::from_utf8_lossy(&o.stdout);
    let err = String::from_utf8_lossy(&o.stderr);
    assert_eq!(got.trim_end(), want.trim_end(), "stderr: {err}");
    assert!(o.status.success());
    // hold's globals hold a trait union, so hold is built from source, and so is geo2, which uses
    // it; voltc says why. std and geo still come from their libraries
    assert_eq!(err.matches("hold's library isn't used: its global 'spare' holds a trait union").count(), 1, "stderr: {err}");
    assert!(err.contains("geo2's library isn't used: it uses hold, which is built from source"), "stderr: {err}");
    assert!(!err.contains("std's library") && !err.contains("geo's library"), "stderr: {err}");
    // a debug library can't go into a release program
    let o = voltc(&[&["run", prog, "--release", "--link", &std_link][..], &pkgs].concat());
    assert!(!o.status.success() && String::from_utf8_lossy(&o.stderr).contains("rebuild it with voltc lib std"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// std::softfloat's quad routines under compiler-rt's names (what LLVM calls for f128): defined for
/// macOS (arm64 and x86-64), whose C runtime has none, and os=none (bare metal, WebAssembly: no C
/// runtime at all), the same set for each, and nowhere else (they'd clash with libgcc's)
#[test]
fn quad_exports() {
    const NAMES: [&str; 30] = ["__addtf3", "__subtf3", "__multf3", "__divtf3", "__negtf2", "__eqtf2", "__netf2", "__lttf2", "__letf2", "__getf2", "__gttf2", "__unordtf2", "__extendhftf2", "__extendsftf2", "__extenddftf2", "__trunctfhf2", "__trunctfsf2", "__trunctfdf2", "__fixtfsi", "__fixtfdi", "__fixtfti", "__fixunstfsi", "__fixunstfdi", "__fixunstfti", "__floatsitf", "__floatditf", "__floattitf", "__floatunsitf", "__floatunditf", "__floatuntitf"];
    let ir = |cfg: &[&str]| {
        let out = Command::new(common::voltc()).args(["emit-llvm", "tests/run/floats_wide.volt", "--std", "std"]).args(cfg).current_dir(env!("CARGO_MANIFEST_DIR")).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    // the quad routines an IR defines: every compiler-rt name with "tf" in it (wasm32's 128-bit
    // integer ones, __multi3 and the like, have none)
    let quad = |ir: &str| -> std::collections::BTreeSet<String> {
        ir.lines().filter(|l| l.starts_with("define")).filter_map(|l| l.split_once("@__")).map(|(_, r)| format!("__{}", r.split('(').next().unwrap())).filter(|n| n.contains("tf")).collect()
    };
    let want: std::collections::BTreeSet<String> = NAMES.iter().map(|n| n.to_string()).collect();
    for arch in ["aarch64", "x86_64"] {
        assert_eq!(quad(&ir(&["--cfg", "os=macos", "--cfg", &format!("arch={arch}")])), want, "{arch} macOS's quad routines");
    }
    let none = quad(&ir(&["--cfg", "os=none", "--cfg", "arch=wasm32"]));
    assert_eq!(none, want, "os=none's quad routines differ from macOS's");
    let win_arm = quad(&ir(&["--cfg", "os=windows", "--cfg", "arch=aarch64"]));
    assert_eq!(win_arm, want, "arm64 Windows' quad routines differ from macOS's");
    // x86-64 Windows has libgcc's (which pass a __float128 as that ABI does, not as LLVM's fp128)
    let win_x64 = quad(&ir(&["--cfg", "os=windows", "--cfg", "arch=x86_64"]));
    assert!(win_x64.is_empty(), "x86-64 Windows defines {win_x64:?}");
    // (Linux named, not the host: on macOS the host is a target that has them)
    let linux = quad(&ir(&["--cfg", "os=linux", "--cfg", "arch=x86_64"]));
    assert!(linux.is_empty(), "Linux defines {linux:?}");
}

/// a global set from ~ or ! over constants is a constant in the IR, with no constructor to set it
#[test]
fn global_fold_has_no_constructor() {
    let o = Command::new(common::voltc()).args(["emit-llvm", "tests/run/global_fold.volt"]).current_dir(env!("CARGO_MANIFEST_DIR")).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let ir = String::from_utf8_lossy(&o.stdout);
    assert!(!ir.contains("llvm.global_ctors"), "global_fold's globals are set by a constructor:\n{ir}");
    // and the C backend writes them (the golden runs use LLVM)
    let src = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/run/global_fold.volt")).unwrap();
    let want = directives(&src, "expect");
    let o = Command::new(common::voltc()).args(["run", "tests/run/global_fold.volt", "--backend", "c"]).current_dir(env!("CARGO_MANIFEST_DIR")).output().unwrap();
    let got = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && got.lines().collect::<Vec<_>>() == want, "global_fold in C printed:\n{got}{}", String::from_utf8_lossy(&o.stderr));
}

/// f128 in C where the compiler has no quad type (arm64 macOS): the C spells every f128 operation
/// volt_q_*, which -DVOLT_SOFT_F128 turns into calls to the quad routines (here libgcc's), so the
/// programs print what they print natively; and arm64 macOS's C compiles, std's quad_rt defining
/// the routines the prelude declares
#[test]
fn f128_soft_c() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let voltc_cc = |args: &[&str], cc: &str| Command::new(common::voltc()).args(args).env("CC", cc).current_dir(root).output().unwrap();
    let voltc = |args: &[&str]| voltc_cc(args, "cc");
    let c = voltc(&["emit-c", "tests/run/floats_wide.volt"]);
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let text = String::from_utf8_lossy(&c.stdout);
    let prelude = include_str!("../runtime/prelude.h");
    for op in ["volt_q_mul(", "volt_q_div(", "volt_q_gt(", "volt_q_hex(", "volt_q_from(f16, ", "volt_q_to(f64, ", "volt_q_to(i64, "] {
        assert!(text.matches(op).count() > prelude.matches(op).count(), "floats_wide's C has no {op}");
    }
    // f128_ops through both C compilers, natively and soft (golden runs them all through LLVM), and
    // f128_exact's constants (T-0477): a native quad type reads volt_q_hex's text, the soft path its bits
    let runs = [("floats_wide", "cc", true), ("softquad", "cc", true), ("f128_ops", "gcc", true), ("f128_ops", "clang", true), ("f128_ops", "gcc", false), ("f128_ops", "clang", false), ("f128_rem", "gcc", true), ("f128_rem", "clang", false), ("f128_exact", "gcc", false), ("f128_exact", "clang", false), ("f128_exact", "clang", true)];
    // Windows: PATH's clang is LLVM's own (MSVC's ABI and libraries) and its gcc another MinGW's, so
    // each runs through $CC, the program's compiler, the way a program builds there: natively on
    // x86-64 (MinGW's __float128), soft on arm64 (no quad type)
    let win_cc = std::env::var("CC").unwrap_or_else(|_| "cc".into());
    for (prog, cc, soft) in runs {
        if cfg!(windows) && cc != "cc" {
            continue;
        }
        let (cc, soft) = if cfg!(windows) { (win_cc.as_str(), cfg!(target_arch = "aarch64")) } else { (cc, soft) };
        let file = format!("tests/run/{prog}.volt");
        let want: Vec<String> = directives(&std::fs::read_to_string(root.join(&file)).unwrap(), "expect");
        let o = voltc_cc(&["run", &file, "--backend", "c", "--cc", if soft { "-DVOLT_SOFT_F128" } else { "-DVOLT_NATIVE" }], cc);
        let got = String::from_utf8_lossy(&o.stdout);
        assert!(o.status.success() && got.lines().collect::<Vec<_>>() == want, "{prog} in C ({cc}, soft {soft}) printed:\n{got}{}", String::from_utf8_lossy(&o.stderr));
    }
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("f128-soft-c");
    std::fs::create_dir_all(&dir).unwrap();
    for prog in ["floats_wide", "f128_ops"] {
        let mac = voltc(&["emit-c", &format!("tests/run/{prog}.volt"), "--cfg", "os=macos", "--cfg", "arch=aarch64"]);
        assert!(mac.status.success(), "{}", String::from_utf8_lossy(&mac.stderr));
        let (src, obj) = (dir.join(format!("{prog}.c")), dir.join(format!("{prog}.o")));
        std::fs::write(&src, &mac.stdout).unwrap();
        let cc = Command::new(common::llvm_tool("clang")).args(["--target=arm64-apple-macos11", "-ffreestanding", "-w", "-c"]).arg(&src).arg("-o").arg(&obj).output().unwrap();
        assert!(cc.status.success(), "{prog}'s C doesn't compile for arm64 macOS:\n{}", String::from_utf8_lossy(&cc.stderr));
        let nm = Command::new(common::llvm_tool("llvm-nm")).args(["-U", "-j"]).arg(&obj).output().unwrap();
        let defined = String::from_utf8_lossy(&nm.stdout);
        assert!(["___addtf3", "___multf3", "___lttf2", "___extendhftf2"].iter().all(|n| defined.lines().any(|l| l == *n)), "arm64 macOS's C defines no quad routines:\n{defined}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// u128 literals past i128's maximum through the C backend too (golden runs them through LLVM)
#[test]
fn u128_literals_c() {
    let file = "tests/run/u128_literals.volt";
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let o = Command::new(common::voltc()).args(["run", file, "--backend", "c"]).current_dir(root).output().unwrap();
    let got = String::from_utf8_lossy(&o.stdout);
    let want = directives(&std::fs::read_to_string(root.join(file)).unwrap(), "expect").join("\n");
    assert!(o.status.success() && got.trim_end() == want, "u128_literals in C printed:\n{got}{}", String::from_utf8_lossy(&o.stderr));
}

/// tests/run/strings_multiline.volt saved with Windows line endings prints the same: a \r\n in a
/// multi-line string is a \n
#[test]
fn multiline_strings_crlf() {
    let src = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/run/strings_multiline.volt")).unwrap();
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("crlf-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("crlf.volt");
    std::fs::write(&f, src.replace('\n', "\r\n")).unwrap();
    let out = Command::new(common::voltc()).arg("run").arg(&f).output().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim_end(), directives(&src, "expect").join("\n"), "{}", String::from_utf8_lossy(&out.stderr));
}

/// examples/units.volt: one comptime call declares a fn for every pair of its 40 units, which
/// voltc expand lists (the example says so)
#[test]
fn units_example_expands() {
    let out = Command::new(common::voltc())
        .args(["expand", "units.volt", "--std", "../std"])
        .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("examples"))
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    let fns = text.lines().filter(|l| l.contains(": attach fn ") && l.contains("_to_")).count();
    assert_eq!(fns, 40 * 39, "fns units.volt's one call declared: {text}");
}
