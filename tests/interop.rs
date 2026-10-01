// Interop both ways, with the self-hosted voltc (it links libLLVM and libclang): a Volt library
// built with `voltc lib --shared/--static` and called from C, C++, Rust, Python (and Zig, when it's
// installed) through `voltc bindings`; Volt calling a Rust static library and embedding Python;
// and Volt importing C++ headers (`use cpp`). Every Volt side runs on both backends.
mod common;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// what every language's mathlib client prints: plain C types, then owned text, slices, optionals, a
/// callback with the caller's data and an export struct (shims voltc lib adds)
const MATHLIB_OUT: &str = "add 5\ndot 11\nscale 2 4\nlen 5\nnext 2\nsqrt 3 1\nerror negative\ngreet hello, volt\nrepeat abab\nrepeat negative\nsum 6.5\nfind 2 none\neach 4 5 6 = 15\ncounter clicks 5\ntake negative\n";

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

/// node's include directory (with node_api.h), when node is installed
fn node_include() -> Option<String> {
    let o = Command::new("node").args(["-p", "require('path').join(process.execPath, '..', '..', 'include', 'node')"]).output().ok()?;
    let dir = String::from_utf8_lossy(&o.stdout).trim().to_string();
    for d in [dir.as_str(), "/usr/include/node", "/usr/local/include/node"] {
        if Path::new(d).join("node_api.h").is_file() {
            return Some(d.to_string());
        }
    }
    None
}

/// a tool on the PATH, or in ~/.local/bin (where a downloaded toolchain goes); `arg` makes it
/// succeed when it works
fn local_tool(name: &str, arg: &str) -> Option<PathBuf> {
    if Command::new(name).arg(arg).output().is_ok_and(|o| o.status.success()) {
        return Some(PathBuf::from(name));
    }
    let local = Path::new(&std::env::var_os("HOME")?).join(".local/bin").join(name);
    local.is_file().then_some(local)
}

/// the bin directory of a JDK 22 or later (javac on the PATH, or ~/.local/share/jdk/current)
fn jdk_bin() -> Option<PathBuf> {
    let new_enough = |javac: &Path| {
        Command::new(javac).arg("-version").output().ok().filter(|o| o.status.success()).is_some_and(|o| {
            let v = String::from_utf8_lossy(&o.stdout).to_string() + &String::from_utf8_lossy(&o.stderr);
            v.split_whitespace().nth(1).and_then(|s| s.split('.').next()?.parse::<u32>().ok()).is_some_and(|major| major >= 22)
        })
    };
    if new_enough(Path::new("javac")) {
        return Some(PathBuf::new()); // bin.join("javac") is just "javac", found on the PATH
    }
    let local = Path::new(&std::env::var_os("HOME")?).join(".local/share/jdk/current/bin");
    new_enough(&local.join("javac")).then_some(local)
}

fn zig() -> Option<PathBuf> {
    local_tool("zig", "version")
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
    for (lang, file) in [("c", "mathlib.h"), ("cpp", "mathlib.hpp"), ("rust", "mathlib.rs"), ("python", "mathlib.py"), ("pyi", "mathlib.pyi"), ("csharp", "mathlib.cs"), ("java", "mathlib.java"), ("zig", "mathlib.zig"), ("node", "mathlib_node.c"), ("js", "mathlib.js"), ("ts", "mathlib.d.ts")] {
        ok(e.voltc(&["bindings", "mathlib", "--pkg", pkg, "--lang", lang, "-o", &e.path(file)]), &format!("voltc bindings --lang {lang}"));
    }
    // the model the generators share, as JSON for generators of other people's
    let json = ok(e.voltc(&["bindings", "mathlib", "--pkg", pkg, "--lang", "json"]), "voltc bindings --lang json");
    for want in [
        r#""package":"mathlib""#,
        r#"{"kind":"class","name":"counter","c_name":"mathlib_counter","free":"counter_free"}"#,
        r#"{"kind":"error_set","name":"math_error","codes":[{"name":"NEGATIVE","code":3930732238}]}"#,
        r#"{"name":"counter_add","params":[{"name":"c","type":{"kind":"handle","class":"counter","owned":false,"nullable":false}},{"name":"by","type":{"kind":"i64"}}],"returns":{"kind":"i64"},"class":"counter","method":"add","static":false"#,
        r#"{"name":"ml_each","params":[{"name":"xs","type":{"kind":"slice","of":{"kind":"i32"}}},{"name":"f","type":{"kind":"callback","params":[{"kind":"i32"}],"returns":{"kind":"void"}}}]"#,
        r#""returns":{"kind":"result","error":"math_error","value":{"kind":"text"},"c_name":"mathlib_math_error_or_text"}"#,
        r#""returns":{"kind":"optional","of":{"kind":"usize"}}"#,
    ] {
        assert!(json.contains(want), "the JSON model lacks {want}:\n{json}");
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
        // the stubs parse, and mypy (when it's installed) checks the client against them
        let parse = format!("import ast; ast.parse(open({:?}).read())", e.path("mathlib.pyi"));
        ok(run(Command::new("python3").args(["-c", &parse])), "parse mathlib.pyi");
        if Command::new("mypy").arg("--version").output().is_ok_and(|o| o.status.success()) {
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.py"), e.dir.join("client.py")).unwrap();
            ok(Command::new("mypy").args(["--strict", "client.py"]).current_dir(&e.dir).output().unwrap(), "mypy --strict client.py");
        }
        // JavaScript: the Node-API addon, built against node's own headers, then node and bun run the
        // clients (TypeScript by stripping its types; tsc checks them when it's installed)
        match node_include() {
            Some(inc) => {
                ok(run(Command::new("cc").args(["-shared", "-fPIC", "-I", &inc]).arg(e.dir.join("mathlib_node.c")).args(["-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(e.dir.join("mathlib.node"))), "cc mathlib_node.c");
                for client in ["client.js", "client.mts"] {
                    std::fs::copy(Path::new(ROOT).join("tests/interop").join(client), e.dir.join(client)).unwrap();
                    let n = Command::new("node").arg(client).current_dir(&e.dir).output().unwrap();
                    assert_eq!(ok(n, &format!("node {client}")), MATHLIB_OUT, "node {client} ({backend})");
                    if Command::new("bun").arg("--version").output().is_ok_and(|o| o.status.success()) {
                        let b = Command::new("bun").arg(client).current_dir(&e.dir).output().unwrap();
                        assert_eq!(ok(b, &format!("bun {client}")), MATHLIB_OUT, "bun {client} ({backend})");
                    }
                }
                // what it rejects, and how
                std::fs::copy(Path::new(ROOT).join("tests/interop/client_edges.js"), e.dir.join("client_edges.js")).unwrap();
                let n = Command::new("node").arg("client_edges.js").current_dir(&e.dir).output().unwrap();
                let want = "too big for i32 RangeError\nNaN TypeError\nInfinity TypeError\nfraction for i32 TypeError\nstring for a number TypeError\nnot a counter TypeError\nclosed counter TypeError\nbigint 2\n";
                assert_eq!(ok(n, "node client_edges.js"), want, "node client_edges.js ({backend})");
                if Command::new("tsc").arg("--version").output().is_ok_and(|o| o.status.success()) {
                    ok(Command::new("tsc").args(["--noEmit", "--strict", "--module", "nodenext", "--moduleResolution", "nodenext", "--target", "es2022", "client.mts"]).current_dir(&e.dir).output().unwrap(), "tsc client.mts");
                }
            }
            None => eprintln!("node isn't installed (or has no headers): skipping the JavaScript clients"),
        }
        // C#: a console project around the generated mathlib.cs
        match local_tool("dotnet", "--version") {
            Some(dotnet) => {
                let v = String::from_utf8_lossy(&Command::new(&dotnet).arg("--version").output().unwrap().stdout).trim().to_string();
                let major = v.split('.').next().unwrap_or("10").to_string();
                let proj = e.dir.join(format!("cs-{backend}"));
                std::fs::create_dir_all(&proj).unwrap();
                std::fs::copy(e.dir.join("mathlib.cs"), proj.join("mathlib.cs")).unwrap();
                std::fs::copy(Path::new(ROOT).join("tests/interop/Client.cs"), proj.join("Client.cs")).unwrap();
                std::fs::write(proj.join("Client.csproj"), format!("<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n    <TargetFramework>net{major}.0</TargetFramework>\n    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>\n    <Nullable>enable</Nullable>\n    <InvariantGlobalization>true</InvariantGlobalization>\n    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>\n  </PropertyGroup>\n</Project>\n")).unwrap();
                let o = Command::new(&dotnet).args(["run", "--nologo"]).current_dir(&proj).env("LD_LIBRARY_PATH", &lib_dir).env("DOTNET_CLI_TELEMETRY_OPTOUT", "1").env("DOTNET_NOLOGO", "1").env("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1").output().unwrap();
                assert_eq!(ok(o, "dotnet run"), MATHLIB_OUT, "C# ({backend})");
            }
            None => eprintln!("dotnet isn't installed: skipping the C# client"),
        }
        // Java (22 or later): the FFM API, compiled with javac
        match jdk_bin() {
            Some(bin) => {
                let jdir = e.dir.join(format!("java-{backend}"));
                std::fs::create_dir_all(&jdir).unwrap();
                std::fs::copy(e.dir.join("mathlib.java"), jdir.join("mathlib.java")).unwrap();
                std::fs::copy(Path::new(ROOT).join("tests/interop/Client.java"), jdir.join("Client.java")).unwrap();
                ok(Command::new(bin.join("javac")).args(["-Xlint:all", "-Werror", "-d", "classes", "mathlib.java", "Client.java"]).current_dir(&jdir).output().unwrap(), "javac");
                let o = Command::new(bin.join("java")).args(["--enable-native-access=ALL-UNNAMED", "-cp", "classes", "Client"]).current_dir(&jdir).env("LD_LIBRARY_PATH", &lib_dir).output().unwrap();
                assert_eq!(ok(o, "java Client"), MATHLIB_OUT, "Java ({backend})");
            }
            None => eprintln!("no JDK 22 or later (javac): skipping the Java client"),
        }
        if let Some(zig) = zig() {
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.zig"), e.dir.join("client.zig")).unwrap();
            // on Linux, Zig's own glibc start files: newer system ones can have sections Zig's linker
            // doesn't read (.sframe)
            let mut target = Vec::new();
            if cfg!(target_os = "linux") {
                target = vec!["-target".to_string(), format!("{}-linux-gnu", std::env::consts::ARCH)];
            }
            let z = Command::new(zig).args(["run", "client.zig"]).args(&target).args(["-lc", "-L", &lib_dir, "-lmathlib"]).current_dir(&e.dir).env("LD_LIBRARY_PATH", &lib_dir).output().unwrap();
            assert!(z.status.success(), "zig run: {}", String::from_utf8_lossy(&z.stderr));
            assert_eq!(String::from_utf8_lossy(&z.stderr), MATHLIB_OUT, "Zig ({backend})");
        } else {
            eprintln!("zig isn't installed: skipping the Zig client");
        }
    }
    // bolt builds them too: [lib] kind and bindings
    let pkg_dir = e.dir.join("pkg");
    std::fs::create_dir_all(pkg_dir.join("lib")).unwrap();
    std::fs::write(pkg_dir.join("bolt.toml"), "[package]\nname = \"twice\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"volt\", \"shared\", \"static\"]\nbindings = [\"c\", \"python\", \"node\", \"ts\"]\n\n[std]\npath = \"STD\"\n".replace("STD", &Path::new(ROOT).join("std").display().to_string())).unwrap();
    std::fs::write(pkg_dir.join("lib/twice.volt"), "export fn twice(x: i32) -> i32 { return x * 2; }\n").unwrap();
    let b = Command::new(env!("CARGO_BIN_EXE_bolt")).arg("build").current_dir(&pkg_dir).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).output().unwrap();
    assert!(b.status.success(), "bolt build: {}", String::from_utf8_lossy(&b.stderr));
    for f in ["libtwice.so", "libtwice.a", "deps/libtwice.a", "bindings/twice.h", "bindings/twice.py", "bindings/twice_node.c", "bindings/twice.d.ts"] {
        assert!(pkg_dir.join("target/debug").join(f).is_file(), "bolt didn't make target/debug/{f}");
    }

    // what bindings can't express is an error that says why
    let bad = e.dir.join("bad");
    std::fs::create_dir_all(&bad).unwrap();
    std::fs::write(bad.join("bad.volt"), "fn pair() -> (i32, i32) { return (1, 2); }\nexport fn bad_pair(x: (i32, i32)) -> i32 { return x.0; }\n").unwrap();
    let o = e.voltc(&["bindings", "bad", "--pkg", &format!("bad={}", bad.display()), "--lang", "c"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("bad_pair") && err.contains("(i32, i32)"), "{err}");
    // owned values only come out, closures only go in
    for (src, want) in [
        ("export struct thing { n: i32; }\nexport fn bad_in(t: thing) -> i32 { return t.n; }\n", "only comes out of export fns"),
        ("fn twice(x: i32) -> i32 { return x * 2; }\nexport fn bad_out() -> fn(i32) -> i32 { return twice; }\n", "closures only go into export fns"),
        // the names voltc lib adds itself
        ("export struct thing { n: i32; }\nexport fn thing_new() -> thing { return { n: 1 }; }\nexport fn thing_free(t: thing&) -> void {}\n", "makes thing_free itself"),
        ("namespace __export { fn x() -> void {} }\nexport fn one() -> i32 { return 1; }\n", "namespace __export"),
    ] {
        std::fs::write(bad.join("bad.volt"), src).unwrap();
        let o = e.voltc(&["bindings", "bad", "--pkg", &format!("bad={}", bad.display()), "--lang", "c"]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains(want), "{err}");
    }
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
