// Embedded Volt: voltc/embed builds the compiler into libvoltvm (bolt, with its bindings), and a C
// program, a Python one and a Rust one run Volt through it: tests/embed/host.c, host.py and host.rs.
// The C host runs with no C compiler on PATH, since nothing at run time should need one.
mod common;
use std::path::Path;
use std::process::{Command, Output};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

const C_OUT: &str = "add 42\ncount 2\nhello from volt 2\nsecond\nmissing 0\nbad: error: expected i32, found str\nnext -2147483648\nsandboxed 4\nescape: Symbols not found: [ getpid ] (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)\ninner: Symbols not found: [ volt_vm_new ] (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)\nallow: a sandbox's allowances are fixed at its first load\n";
const PACKAGES_OUT: &str = "vm run 393\nreload util: can't load util.volt again: main_script uses it\nvm run 395\nvm leaf 1\nvm leaf 2\nbox run 393\nreload util: can't load util.volt again: main_script uses it\nbox run 395\nbox leaf 1\nbox leaf 2\nbroken: error: expected i32, found str\nuser: error: unknown name 'broken'\nmissing: Symbols not found: [ not_a_function_anywhere ]\nm 5\nmissing replaced: Symbols not found: [ still_not_anywhere ]\nm found 0\nmy-util.volt: can't load my-util.volt: a script is the package its file names, and my-util can't name a package\nstd.volt: can't load std.volt: a script is the package its file names, and std is std's\ndir/fn.volt: can't load dir/fn.volt: a script is the package its file names, and fn can't name a package\nb/init: can't load b/init.volt: its package, init, is a/init.volt's (load a/init.volt again to replace it, or give this one another name)\na_init 1\nh 7\nwide: error: the global shapes::held holds shape's union, laid out (and shapes's code built) for the types attached when shapes loaded: a later script can't attach shape to another type\nheld 36\nnamed 3\nboxy: error: the global holders::two holds boxy's union, laid out (and holders's code built) for the types attached when holders loaded: a later script can't attach boxy to another type\nfieldy: error: the global holders::held_slot holds fieldy's union, laid out (and holders's code built) for the types attached when holders loaded: a later script can't attach fieldy to another type\nspin: error: the export fn takers::spun takes or gives spin's union, laid out (and takers's code built) for the types attached when takers loaded: a later script can't attach spin to another type\nturn: error: the export fn takers::turned takes or gives turn's union, laid out (and takers's code built) for the types attached when takers loaded: a later script can't attach turn to another type\nspun 9\ncube again: can't load cube.volt again: the global tank::held holds solid's union, laid out (and tank's code built) for the types attached when tank loaded, cube's among them\nrod 5 cube 8\ndrip again: can't load drip.volt again: the export fn pipe::pipe takes or gives fluid's union, laid out (and pipe's code built) for the types attached when pipe loaded, drip's among them\n";
const IMPORTS_OUT: &str = "run 53\nuser 54\nthrice 15\nstd 9 13, kept\nreload hv 10\nreload hv 20\nreload inner hv 30\nreload inner hv 40\nheader fn 10 20\nheader fn after a failed load 40\nheader removed, next load 7\nheader removed, a header fn 8\nheader inline 10 20\ncpp removed 5, removed, next load 8, kin.h edited, next load 9, a new importer refused naming it, put back 70\nkept removed 6, removed, next load 8, kin.h edited, next load 9, a new importer refused naming it, put back 71\nbox run 53\nbox imports user 54\nbox thrice 15\nbox strlen 4\nbox user 8\nbox_pid: Symbols not found: [ getpid ] (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)\nbox_gxx: a sandbox's script imports C++ through clang++ (LLVM bitcode, run by the JIT under the sandbox), and $CXX is g++\nbox header fn 10 20\nbox header fn after a failed load 40\n";
const PY_OUT: &str = "sum_squares 385\nerror COMPILE error: unknown name 'nope'\n";
const RS_OUT: &str = "cubes 100\nerror COMPILE error: expected an expression, found ';'\n";

/// stdout of a command that must succeed
fn ok(o: Output, what: &str) -> String {
    let out = String::from_utf8_lossy(&o.stdout).replace("\r\n", "\n"); // (Windows' text-mode stdout)
    assert!(o.status.success(), "{what} failed ({})\n--- stdout\n{out}\n--- stderr\n{}", o.status, String::from_utf8_lossy(&o.stderr));
    out
}

#[test]
fn embedded_volt() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("embed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // stage 1 builds libvoltvm through bolt
    let voltc = common::voltc();
    let target = dir.join("target");
    ok(Command::new(env!("CARGO_BIN_EXE_bolt")).args(["build", "-q", "--target-dir"]).arg(&target).current_dir(Path::new(ROOT).join("voltc/embed")).env("VOLTC", &voltc).env("BOLT_HOME", dir.join("bolthome")).output().unwrap(), "bolt build voltc/embed");
    let lib_dir = target.join("debug");
    let bindings = lib_dir.join("bindings");
    let std_dir = Path::new(ROOT).join("std");
    let bindir = ["llvm-config-23", "llvm-config"].iter().find_map(|t| Command::new(std::env::var("LLVM_CONFIG").unwrap_or(t.to_string())).arg("--bindir").output().ok().filter(|o| o.status.success())).map(|o| Path::new(String::from_utf8_lossy(&o.stdout).trim()).to_path_buf());
    // Windows has no rpath: a program finds its DLLs beside it, so the hosts are built next to
    // voltvm.dll, with LLVM's DLLs it links copied there (the first host runs with no PATH at all)
    let exe_dir = if cfg!(windows) { lib_dir.clone() } else { dir.clone() };
    if cfg!(windows) {
        let b = bindir.clone().expect("llvm-config --bindir (LLVM's DLLs)");
        for dll in ["LLVM-C.dll", "libclang.dll"] {
            std::fs::copy(b.join(dll), lib_dir.join(dll)).unwrap();
        }
    }
    // the C host: built here, run where no C compiler can be found
    let host = exe_dir.join("host");
    ok(Command::new("cc").arg("-o").arg(&host).arg(Path::new(ROOT).join("tests/embed/host.c")).arg("-I").arg(&bindings).arg("-L").arg(&lib_dir).arg("-lvoltvm").arg(format!("-Wl,-rpath,{}", lib_dir.display())).output().unwrap(), "compiling host.c");
    let mut c = Command::new(&host);
    c.arg(&std_dir).env_clear().env("PATH", "/nonexistent");
    if let Some(root) = std::env::var_os("SYSTEMROOT") {
        c.env("SYSTEMROOT", root); // (Windows' own DLLs need it)
    }
    let out = ok(c.output().unwrap(), "host");
    assert_eq!(out, C_OUT);
    {
        // a script importing a C header and a C++ one, with the compilers on PATH: their code is
        // compiled for it as it loads
        let imports = exe_dir.join("host_imports");
        ok(Command::new("cc").arg("-o").arg(&imports).arg(Path::new(ROOT).join("tests/embed/host_imports.c")).arg("-I").arg(&bindings).arg("-L").arg(&lib_dir).arg("-lvoltvm").arg(format!("-Wl,-rpath,{}", lib_dir.display())).output().unwrap(), "compiling host_imports.c");
        // and in a sandbox through clang of the VM's LLVM (llvm-config's), when it's there
        let clang = bindir.filter(|b| cfg!(target_os = "linux") && b.join("clang").is_file() && b.join("clang++").is_file());
        let mut c = Command::new(&imports);
        c.arg(&std_dir).arg(Path::new(ROOT).join("tests/embed"));
        // Apple's clang++ has no std module (no libc++ modules manifest): on macOS, the clang++ of
        // the LLVM voltc uses, as cpp_module has it
        if cfg!(target_os = "macos") {
            c.env("CXX", common::llvm_tool("clang++"));
        }
        if let Some(b) = &clang {
            c.arg("box").env("CC", b.join("clang")).env("CXX", b.join("clang++"));
        }
        let out = ok(c.output().unwrap(), "host_imports");
        // (Windows: no std module case, which watches $CXX through a sh wrapper)
        let std_line = if cfg!(windows) { "" } else { "std 9 13, kept\n" };
        let native = format!("run 53\nuser 54\nthrice 15\n{std_line}reload hv 10\nreload hv 20\nreload inner hv 30\nreload inner hv 40\nheader fn 10 20\nheader fn after a failed load 40\nheader removed, next load 7\nheader removed, a header fn 8\nheader inline 10 20\ncpp removed 5, removed, next load 8, kin.h edited, next load 9, a new importer refused naming it, put back 70\nkept removed 6, removed, next load 8, kin.h edited, next load 9, a new importer refused naming it, put back 71\n");
        assert_eq!(out, if clang.is_some() { IMPORTS_OUT } else { native.as_str() });
        // a C compiler that rejects -H (tcc does): the headers it read aren't listed, so only those the
        // #include lines name are watched (an edit to one they include isn't seen: inner hv stays 30)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let cc = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).map(|d| d.join("cc")).find(|p| p.is_file()).expect("cc on PATH");
            let wrap = dir.join("cc-no-H");
            std::fs::write(&wrap, format!("#!/bin/sh\nfor a in \"$@\"; do\n    [ \"$a\" = -H ] && {{ echo 'cc: unknown option -H' >&2; exit 1; }}\ndone\nexec '{}' \"$@\"\n", cc.display())).unwrap();
            std::fs::set_permissions(&wrap, std::fs::Permissions::from_mode(0o755)).unwrap();
            let out = ok(Command::new(&imports).arg(&std_dir).arg(Path::new(ROOT).join("tests/embed")).env("CC", &wrap).output().unwrap(), "host_imports (a cc without -H)");
            assert_eq!(out, native.replace("inner hv 40", "inner hv 30"));
        }
    }
    // scripts using earlier scripts as packages
    let packages = exe_dir.join("host_packages");
    ok(Command::new("cc").arg("-o").arg(&packages).arg(Path::new(ROOT).join("tests/embed/host_packages.c")).arg("-I").arg(&bindings).arg("-L").arg(&lib_dir).arg("-lvoltvm").arg(format!("-Wl,-rpath,{}", lib_dir.display())).output().unwrap(), "compiling host_packages.c");
    assert_eq!(ok(Command::new(&packages).arg(&std_dir).output().unwrap(), "host_packages"), PACKAGES_OUT);
    // Python, through the generated module (which loads the library without RTLD_GLOBAL)
    if Command::new("python3").arg("--version").output().is_ok_and(|o| o.status.success()) {
        let out = ok(Command::new("python3").arg(Path::new(ROOT).join("tests/embed/host.py")).arg(&std_dir).env("PYTHONPATH", &bindings).env("VOLT_VOLTVM_LIB", lib_dir.join(format!("{}voltvm.{}", std::env::consts::DLL_PREFIX, std::env::consts::DLL_EXTENSION))).output().unwrap(), "host.py");
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
        let mut rc = Command::new("rustc");
        rc.args(["--edition", "2021", "-o"]).arg(&exe).arg(src.join("main.rs")).arg("-L").arg(&lib_dir).args(["-l", "voltvm"]);
        if cfg!(unix) {
            // (Windows has no rpath, and MSVC's link.exe would take the flag for a file)
            rc.arg("-C").arg(format!("link-args=-Wl,-rpath,{}", lib_dir.display()));
        }
        ok(rc.env("RUSTUP_TOOLCHAIN", std::env::var("RUSTUP_TOOLCHAIN").unwrap_or_else(|_| "stable".into())).output().unwrap(), "rustc host.rs");
        assert_eq!(ok(Command::new(&exe).arg(&std_dir).env("PATH", common::path_with(&lib_dir)).output().unwrap(), "host.rs"), RS_OUT);
    }
    let _ = std::fs::remove_dir_all(&dir);
}
