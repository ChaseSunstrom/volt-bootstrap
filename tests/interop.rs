// Interop both ways, with the self-hosted voltc (it links libLLVM and libclang): a Volt library
// built with `voltc lib --shared/--static` and called from C, C++, Rust, Python (and Zig, when it's
// installed) through `voltc bindings`; Volt calling a Rust static library and embedding Python;
// and Volt importing C++ headers (`use cpp`). Every Volt side runs on both backends.
mod common;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// what every language's mathlib client prints
const MATHLIB_OUT: &str = "add 5\ndot 11\nscale 2 4\nlen 5\nnext 2\nsqrt 3 1\nerror negative\n";

/// voltc/src built by the bootstrap compiler, and a scratch directory; both removed when dropped
struct Env {
    voltc: PathBuf,
    dir: PathBuf,
}

impl Env {
    fn new(tag: &str) -> Env {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("interop-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let voltc = dir.join("voltc");
        let mut srcs: Vec<PathBuf> = std::fs::read_dir(Path::new(ROOT).join("voltc/src")).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect();
        srcs.sort();
        let b = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("build").args(&srcs).args(common::llvm_cc_args()).arg("-o").arg(&voltc).output().unwrap();
        assert!(b.status.success(), "building voltc/src failed:\n{}", String::from_utf8_lossy(&b.stderr));
        Env { voltc, dir }
    }
    /// voltc with ROOT's std, in tests/interop
    fn voltc(&self, args: &[&str]) -> Output {
        Command::new(&self.voltc).args(args).arg("--std").arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).output().unwrap()
    }
    fn path(&self, name: &str) -> String {
        self.dir.join(name).display().to_string()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }
}

/// stdout of a command that must succeed
fn ok(o: Output, what: &str) -> String {
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    assert!(o.status.success(), "{what} failed\n--- stdout\n{out}\n--- stderr\n{}", String::from_utf8_lossy(&o.stderr));
    out
}

fn has(tool: &str) -> bool {
    Command::new(tool).arg("--version").output().is_ok_and(|o| o.status.success())
}

fn run(cmd: &mut Command) -> Output {
    cmd.current_dir(Path::new(ROOT).join("tests/interop")).output().unwrap()
}

#[test]
fn bindings_round_trip() {
    let e = Env::new("bindings");
    let pkg = "mathlib=mathlib/lib";
    for backend in ["c", "llvm"] {
        let so = e.path(&format!("{backend}/libmathlib.so"));
        std::fs::create_dir_all(e.dir.join(backend)).unwrap();
        ok(e.voltc(&["lib", "mathlib", "--pkg", pkg, "--shared", "--backend", backend, "-o", &so]), "voltc lib --shared");
        ok(e.voltc(&["lib", "mathlib", "--pkg", pkg, "--static", "--backend", backend, "-o", &e.path(&format!("{backend}/libmathlib_static.a"))]), "voltc lib --static");
    }
    for (lang, file) in [("c", "mathlib.h"), ("cpp", "mathlib.hpp"), ("rust", "mathlib.rs"), ("python", "mathlib.py"), ("zig", "mathlib.zig")] {
        ok(e.voltc(&["bindings", "mathlib", "--pkg", pkg, "--lang", lang, "-o", &e.path(file)]), &format!("voltc bindings --lang {lang}"));
    }
    let bin = |name: &str| e.dir.join(name);
    for backend in ["c", "llvm"] {
        let lib_dir = e.path(backend);
        let rpath = format!("-Wl,-rpath,{lib_dir}");
        // C, against the shared and the static library
        ok(run(Command::new("cc").args(["client.c", "-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(bin("c_shared"))), "cc client.c");
        assert_eq!(ok(Command::new(bin("c_shared")).output().unwrap(), "C program"), MATHLIB_OUT, "C, shared ({backend})");
        ok(run(Command::new("cc").args(["client.c", "-I", &e.path("")]).arg(format!("{lib_dir}/libmathlib_static.a")).arg("-o").arg(bin("c_static"))), "cc client.c (static)");
        assert_eq!(ok(Command::new(bin("c_static")).output().unwrap(), "C program (static)"), MATHLIB_OUT, "C, static ({backend})");
        // C++
        ok(run(Command::new("c++").args(["-std=c++17", "client.cpp", "-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(bin("cpp"))), "c++ client.cpp");
        assert_eq!(ok(Command::new(bin("cpp")).output().unwrap(), "C++ program"), MATHLIB_OUT, "C++ ({backend})");
        // Rust: client.rs next to its mathlib.rs module
        std::fs::copy(Path::new(ROOT).join("tests/interop/client.rs"), e.dir.join("client.rs")).unwrap();
        ok(run(Command::new("rustc").arg(e.dir.join("client.rs")).args(["--edition", "2021", "-L", &lib_dir, "-l", "mathlib", "-C", &format!("link-arg={rpath}"), "-o"]).arg(bin("rs"))), "rustc client.rs");
        assert_eq!(ok(Command::new(bin("rs")).output().unwrap(), "Rust program"), MATHLIB_OUT, "Rust ({backend})");
        // Python: the module loads libmathlib.so from $VOLT_MATHLIB_LIB, else next to itself
        let py = run(Command::new("python3").arg("client.py").env("PYTHONPATH", e.path("")).env("VOLT_MATHLIB_LIB", format!("{lib_dir}/libmathlib.so")));
        assert_eq!(ok(py, "python3 client.py"), MATHLIB_OUT, "Python ({backend})");
        if has("zig") {
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.zig"), e.dir.join("client.zig")).unwrap();
            let z = Command::new("zig").args(["run", "client.zig", "-lc", "-L", &lib_dir, "-lmathlib"]).current_dir(&e.dir).env("LD_LIBRARY_PATH", &lib_dir).output().unwrap();
            assert!(z.status.success(), "zig run: {}", String::from_utf8_lossy(&z.stderr));
            assert_eq!(String::from_utf8_lossy(&z.stderr), MATHLIB_OUT, "Zig ({backend})");
        } else {
            eprintln!("zig isn't installed: skipping the Zig client");
        }
    }
    // bolt builds them too: [lib] kind and bindings
    let pkg_dir = e.dir.join("pkg");
    std::fs::create_dir_all(pkg_dir.join("lib")).unwrap();
    std::fs::write(pkg_dir.join("bolt.toml"), "[package]\nname = \"twice\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"volt\", \"shared\", \"static\"]\nbindings = [\"c\", \"python\"]\n\n[std]\npath = \"STD\"\n".replace("STD", &Path::new(ROOT).join("std").display().to_string())).unwrap();
    std::fs::write(pkg_dir.join("lib/twice.volt"), "export fn twice(x: i32) -> i32 { return x * 2; }\n").unwrap();
    let b = Command::new(env!("CARGO_BIN_EXE_bolt")).arg("build").current_dir(&pkg_dir).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).output().unwrap();
    assert!(b.status.success(), "bolt build: {}", String::from_utf8_lossy(&b.stderr));
    for f in ["libtwice.so", "libtwice.a", "deps/libtwice.a", "bindings/twice.h", "bindings/twice.py"] {
        assert!(pkg_dir.join("target/debug").join(f).is_file(), "bolt didn't make target/debug/{f}");
    }

    // what bindings can't express is an error that says why
    let bad = e.dir.join("bad");
    std::fs::create_dir_all(&bad).unwrap();
    std::fs::write(bad.join("bad.volt"), "fn pair() -> (i32, i32) { return (1, 2); }\nexport fn bad_pair(x: (i32, i32)) -> i32 { return x.0; }\n").unwrap();
    let o = e.voltc(&["bindings", "bad", "--pkg", &format!("bad={}", bad.display()), "--lang", "c"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("bad_pair") && err.contains("(i32, i32)"), "{err}");
}

#[test]
fn volt_calls_rust_and_python() {
    let e = Env::new("out");
    ok(run(Command::new("rustc").args(["--crate-type", "staticlib", "--edition", "2021", "-C", "panic=abort", "rust_lib.rs", "-o"]).arg(e.dir.join("librs.a"))), "rustc --crate-type staticlib");
    let rs = e.path("librs.a");
    for backend in ["c", "llvm"] {
        let out = ok(e.voltc(&["run", "uses_rust.volt", "--backend", backend, "--cc", &rs, "--cc", "-lpthread", "--cc", "-ldl"]), "voltc run uses_rust.volt");
        assert_eq!(out, "rust 9 8\n", "Volt calls Rust ({backend})");
    }
    let flags = |args: &[&str]| Command::new("python3-config").args(args).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().map(String::from).collect::<Vec<_>>());
    let (Some(inc), Some(link)) = (flags(&["--includes"]), flags(&["--embed", "--ldflags"])) else {
        eprintln!("python3-config isn't installed: skipping embedded Python");
        return;
    };
    for backend in ["c", "llvm"] {
        let mut args = vec!["run", "embeds_python.volt", "--backend", backend];
        for f in inc.iter().chain(&link) {
            args.extend(["--cc", f.as_str()]);
        }
        assert_eq!(ok(e.voltc(&args), "voltc run embeds_python.volt"), "python 42\n", "Volt embeds Python ({backend})");
    }
}

#[test]
fn cpp_import() {
    let e = Env::new("cpp");
    let want = "make 2 3\narea 6\nfields 5 6\nscaled 60 15\ncount 7 name rect\nmake 4 4\nkind 4 1\ntotal 46\ncopy 4 4\ncopied 16\ndrop 4 4\ndrop 4 4\ndrop 5 6\nadd 3 3.5\nbiggest 9 2.5\nbox 6\nenum 4 1\nsize 16\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_import.volt", "--backend", backend, "--cc", "-D", "--cc", "SHAPES_FLAG"]), "voltc run cpp_import.volt"), want, "C++ import ({backend})");
        // an exception stops the program with its message
        let o = e.voltc(&["run", "cpp_throws.volt", "--backend", backend, "--cc", "-DSHAPES_FLAG"]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(o.status.code() == Some(101) && err.contains("C++ exception") && err.contains("negative"), "C++ exception ({backend}): {err}");
    }
}
