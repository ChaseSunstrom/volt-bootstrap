// Embedded Volt: voltc/embed builds the compiler into libvoltvm.so (bolt, with its bindings), and a C
// program, a Python one and a Rust one run Volt through it: tests/embed/host.c, host.py and host.rs.
// The C host runs with no C compiler on PATH, since nothing at run time should need one.
mod common;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

const C_OUT: &str = "add 42\ncount 2\nhello from volt 2\nsecond\nmissing 0\nbad: error: expected i32, found str\nnext -2147483648\nsandboxed 4\nescape: Symbols not found: [ getpid ] (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)\ninner: Symbols not found: [ volt_vm_new ] (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)\nallow: a sandbox's allowances are fixed at its first load\n";
const PY_OUT: &str = "sum_squares 385\nerror COMPILE error: unknown name 'nope'\n";
const RS_OUT: &str = "cubes 100\nerror COMPILE error: expected an expression, found ';'\n";

/// stdout of a command that must succeed
fn ok(o: Output, what: &str) -> String {
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    assert!(o.status.success(), "{what} failed\n--- stdout\n{out}\n--- stderr\n{}", String::from_utf8_lossy(&o.stderr));
    out
}

#[test]
fn embedded_volt() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("embed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // voltc, built by the bootstrap; it builds libvoltvm through bolt
    let voltc = dir.join("voltc");
    let mut srcs: Vec<PathBuf> = std::fs::read_dir(Path::new(ROOT).join("voltc/src")).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect();
    srcs.sort();
    ok(Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("build").args(&srcs).args(common::llvm_cc_args()).arg("-o").arg(&voltc).output().unwrap(), "building voltc");
    let target = dir.join("target");
    ok(Command::new(env!("CARGO_BIN_EXE_bolt")).args(["build", "-q", "--target-dir"]).arg(&target).current_dir(Path::new(ROOT).join("voltc/embed")).env("VOLTC", &voltc).env("BOLT_HOME", dir.join("bolthome")).output().unwrap(), "bolt build voltc/embed");
    let lib_dir = target.join("debug");
    let bindings = lib_dir.join("bindings");
    let std_dir = Path::new(ROOT).join("std");
    // the C host: built here, run where no C compiler can be found
    let host = dir.join("host");
    ok(Command::new("cc").arg("-o").arg(&host).arg(Path::new(ROOT).join("tests/embed/host.c")).arg("-I").arg(&bindings).arg("-L").arg(&lib_dir).arg("-lvoltvm").arg(format!("-Wl,-rpath,{}", lib_dir.display())).output().unwrap(), "compiling host.c");
    let out = ok(Command::new(&host).arg(&std_dir).env_clear().env("PATH", "/nonexistent").output().unwrap(), "host");
    assert_eq!(out, C_OUT);
    // Python, through the generated module (which loads the library without RTLD_GLOBAL)
    if Command::new("python3").arg("--version").output().is_ok_and(|o| o.status.success()) {
        let out = ok(Command::new("python3").arg(Path::new(ROOT).join("tests/embed/host.py")).arg(&std_dir).env("PYTHONPATH", &bindings).env("VOLT_VOLTVM_LIB", lib_dir.join("libvoltvm.so")).output().unwrap(), "host.py");
        assert_eq!(out, PY_OUT);
    }
    // Rust, through the generated module, compiled with rustc next to it
    let rustc = Command::new("rustc").arg("--version").env("RUSTUP_TOOLCHAIN", std::env::var("RUSTUP_TOOLCHAIN").unwrap_or_else(|_| "stable".into())).output();
    if rustc.is_ok_and(|o| o.status.success()) {
        let src = dir.join("rs");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::copy(Path::new(ROOT).join("tests/embed/host.rs"), src.join("main.rs")).unwrap();
        std::fs::copy(bindings.join("voltvm.rs"), src.join("voltvm.rs")).unwrap();
        let exe = src.join("host");
        ok(Command::new("rustc").args(["--edition", "2021", "-o"]).arg(&exe).arg(src.join("main.rs")).arg("-L").arg(&lib_dir).args(["-l", "voltvm", "-C"]).arg(format!("link-args=-Wl,-rpath,{}", lib_dir.display())).env("RUSTUP_TOOLCHAIN", std::env::var("RUSTUP_TOOLCHAIN").unwrap_or_else(|_| "stable".into())).output().unwrap(), "rustc host.rs");
        assert_eq!(ok(Command::new(&exe).arg(&std_dir).output().unwrap(), "host.rs"), RS_OUT);
    }
    let _ = std::fs::remove_dir_all(&dir);
}
