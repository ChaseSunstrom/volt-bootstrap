// Golden tests. tests/run/*.volt and examples/*.volt: compiled and run, stdout must equal the `// expect: ` lines
// (and exit code the `// exit: N` line, default 0, or one of `// exit: N|M`; `// flags: --release` passes flags; each `// expect-stderr: ` line must be
// in stderr). tests/fail/*.volt: `voltc check` must fail with every `// error: ` substring in its stderr.
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
        let want = directives(&src, "expect").join("\n");
        // `// exit: 132|133`: any of them (a trap is SIGILL on x86-64, SIGTRAP on arm64)
        let want_codes: Vec<i32> = directives(&src, "exit").first().map(|s| s.split('|').map(|c| c.trim().parse().unwrap()).collect()).unwrap_or(vec![0]);
        let flags: Vec<String> = directives(&src, "flags").iter().flat_map(|l| l.split_whitespace().map(String::from).collect::<Vec<_>>()).collect();
        // a program that hangs (a release build reading out of bounds can) fails instead of stopping the run
        let out = Command::new("timeout").arg("120").arg(&bin).arg("run").arg(&f).args(&flags).output().unwrap();
        let got = String::from_utf8_lossy(&out.stdout);
        let code = out.status.code().unwrap_or(-1);
        let err = String::from_utf8_lossy(&out.stderr);
        let err_missing = directives(&src, "expect-stderr").iter().any(|w| !err.contains(w.as_str()));
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

/// packages precompiled with `voltc lib` and linked: same output as compiling them from source
#[test]
fn std_linked() {
    let bin = common::voltc();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("linked-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let voltc = |args: &[&str]| Command::new(&bin).args(args).current_dir(root).output().unwrap();
    let (std_a, geo_a) = (dir.join("libstd.a"), dir.join("libgeo.a"));
    let (std_a, geo_a) = (std_a.to_str().unwrap(), geo_a.to_str().unwrap());
    for (pkg, out) in [("std", std_a), ("geo", geo_a)] {
        let o = voltc(&["lib", pkg, "--pkg", "geo=tests/pkgs/geo", "-o", out]);
        assert!(o.status.success(), "voltc lib {pkg}: {}", String::from_utf8_lossy(&o.stderr));
    }
    let prog = "tests/run/packages_linked.volt";
    let want = directives(&std::fs::read_to_string(root.join(prog)).unwrap(), "expect").join("\n");
    let std_link = format!("std={std_a}");
    let geo_link = format!("geo={geo_a}");
    let o = voltc(&["run", prog, "--pkg", "geo=tests/pkgs/geo", "--leak-check", "--link", &std_link, "--link", &geo_link]);
    let got = String::from_utf8_lossy(&o.stdout);
    assert_eq!(got.trim_end(), want.trim_end(), "stderr: {}", String::from_utf8_lossy(&o.stderr));
    assert!(o.status.success());
    // a debug library can't go into a release program
    let o = voltc(&["run", prog, "--pkg", "geo=tests/pkgs/geo", "--release", "--link", &std_link]);
    assert!(!o.status.success() && String::from_utf8_lossy(&o.stderr).contains("rebuild it with voltc lib std"));
    let _ = std::fs::remove_dir_all(&dir);
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
