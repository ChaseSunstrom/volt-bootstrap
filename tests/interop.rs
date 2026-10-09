// Interop both ways, with the self-hosted voltc (it links libLLVM and libclang): a Volt library
// built with `voltc lib --shared/--static` and called from C, C++, Rust and Python (and Zig,
// JavaScript, C#, Java, Go, Lua, Dart, Swift, Kotlin/Native and Ruby, when they're installed)
// through `voltc bindings`; Volt calling a Rust static library and embedding Python; and Volt
// importing C++ headers (`use cpp`). Every Volt side runs on both backends.
mod common;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// what every language's mathlib client prints: plain C types, then owned text, slices, optionals, a
/// callback with the caller's data and an export struct (shims voltc lib adds)
const MATHLIB_OUT: &str = "add 5\ndot 11\nscale 2 4\nlen 5\nclash 895\ntags 1 2 3 4 34\nbump 8 5\nnext 2\nsqrt 3 1\nerror negative\ngreet hello, volt\nrepeat abab\nrepeat negative\nsum 6.5\nfind 2 none\neach 4 5 6 = 15\ncounter clicks 5\ntake negative\nlabel 15\nlabel_of ab 3 6 9 1.5\nlabels 36\nholder 3\nor 4.5 9.5\nask 18\nrelabel ab 7 6 9\ncount 40\nnote 7\nor_label 15 -1\ngiven 66 9.5\n";

/// stage 1 (common::voltc), and a scratch directory, removed when dropped
struct Env {
    voltc: PathBuf,
    dir: PathBuf,
}

impl Env {
    fn new(tag: &str) -> Env {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("interop-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Env { voltc: common::voltc(), dir }
    }
    /// voltc with ROOT's std, in tests/interop
    fn voltc(&self, args: &[&str]) -> Output {
        self.voltc_cxx(args, None)
    }
    /// with $CXX set (the C++ compiler, and its flags)
    fn voltc_cxx(&self, args: &[&str], cxx: Option<&str>) -> Output {
        let mut c = Command::new(&self.voltc);
        c.args(args).arg("--std").arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop"));
        if let Some(x) = cxx {
            c.env("CXX", x);
        }
        c.output().unwrap()
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

/// where Lua's headers are (lua.h), when lua is installed
fn lua_include() -> Option<&'static str> {
    Command::new("lua").arg("-v").output().ok().filter(|o| o.status.success())?;
    ["/usr/include", "/usr/include/lua5.5", "/usr/include/lua5.4", "/usr/local/include"].into_iter().find(|d| Path::new(d).join("lua.h").is_file())
}

/// ruby, and the directories of its headers (ruby.h and its config.h), when both are installed
fn ruby_headers() -> Option<(PathBuf, Vec<String>)> {
    let ruby = local_tool("ruby", "-v")?;
    let o = Command::new(&ruby).args(["-e", "print RbConfig::CONFIG['rubyhdrdir'], ' ', RbConfig::CONFIG['rubyarchhdrdir']"]).output().ok()?;
    let dirs: Vec<String> = String::from_utf8_lossy(&o.stdout).split_whitespace().map(String::from).collect();
    (dirs.len() == 2 && Path::new(&dirs[0]).join("ruby.h").is_file()).then_some((ruby, dirs))
}

/// cc building Ruby extension src against library lib (in lib_dir), with the leak report linked in
/// (it prints the library's live allocations at exit, once Ruby has freed its objects); -o next
fn ruby_ext(hdrs: &[String], src: &Path, lib_dir: &str, lib: &str) -> Command {
    let mut cc = Command::new("cc");
    cc.args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror"]);
    for h in hdrs {
        cc.arg("-I").arg(h);
    }
    cc.arg(src).args(["leak_report.c", "-L", lib_dir, &format!("-l{lib}"), &format!("-Wl,-rpath,{lib_dir}"), "-o"]);
    cc
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
    for (lang, file) in [("c", "mathlib.h"), ("cpp", "mathlib.hpp"), ("rust", "mathlib.rs"), ("python", "mathlib.py"), ("pyi", "mathlib.pyi"), ("csharp", "mathlib.cs"), ("java", "mathlib.java"), ("go", "mathlib.go"), ("lua", "mathlib_lua.c"), ("dart", "mathlib.dart"), ("swift", "mathlib.swift"), ("kotlin", "mathlib.kt"), ("ruby", "mathlib_ruby.c"), ("zig", "mathlib.zig"), ("node", "mathlib_node.c"), ("js", "mathlib.js"), ("ts", "mathlib.d.ts")] {
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
                ok(run(Command::new("cc").args(["-shared", "-fPIC", "-Wall", "-Werror", "-I", &inc]).arg(e.dir.join("mathlib_node.c")).args(["-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(e.dir.join("mathlib.node"))), "cc mathlib_node.c");
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
                    ok(Command::new("tsc").args(["--noEmit", "--strict", "--module", "nodenext", "--moduleResolution", "nodenext", "--target", "es2022", "--types", "node", "client.mts"]).current_dir(&e.dir).output().unwrap(), "tsc client.mts");
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
        // Go: a module with the generated cgo package, built against the library
        if Command::new("go").arg("version").output().is_ok_and(|o| o.status.success()) {
            let gdir = e.dir.join(format!("go-{backend}"));
            std::fs::create_dir_all(gdir.join("mathlib")).unwrap();
            std::fs::copy(e.dir.join("mathlib.go"), gdir.join("mathlib/mathlib.go")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.go"), gdir.join("main.go")).unwrap();
            std::fs::write(gdir.join("go.mod"), "module client\n\ngo 1.22\n").unwrap();
            let flags = format!("-L{lib_dir} -Wl,-rpath,{lib_dir}");
            let go = |args: &[&str]| Command::new("go").args(args).current_dir(&gdir).env("CGO_LDFLAGS", &flags).env("GOFLAGS", "-mod=mod").env("GOPROXY", "off").output().unwrap();
            ok(go(&["vet", "./..."]), "go vet");
            let unformatted = ok(Command::new("gofmt").args(["-l", "mathlib"]).current_dir(&gdir).output().unwrap(), "gofmt -l");
            assert_eq!(unformatted, "", "gofmt would change the Go bindings ({backend})");
            assert_eq!(ok(go(&["run", "."]), "go run"), MATHLIB_OUT, "Go ({backend})");
        } else {
            eprintln!("go isn't installed: skipping the Go client");
        }
        // Lua: the C module, built against Lua's headers; client.lua also asserts what it rejects
        if let Some(inc) = lua_include() {
            let ldir = e.dir.join(format!("lua-{backend}"));
            std::fs::create_dir_all(&ldir).unwrap();
            ok(run(Command::new("cc").args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-I", inc]).arg(e.dir.join("mathlib_lua.c")).args(["-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(ldir.join("mathlib.so"))), "cc mathlib_lua.c");
            let l = Command::new("lua").arg(Path::new(ROOT).join("tests/interop/client.lua")).env("LUA_CPATH", ldir.join("?.so")).output().unwrap();
            assert_eq!(ok(l, "lua client.lua"), MATHLIB_OUT, "Lua ({backend})");
        } else {
            eprintln!("lua (5.4 or later, with its headers) isn't installed: skipping the Lua client");
        }
        // Dart: mathlib.dart over dart:ffi; dart analyze checks it and the client
        if let Some(dart) = local_tool("dart", "--version") {
            let ddir = e.dir.join(format!("dart-{backend}"));
            std::fs::create_dir_all(&ddir).unwrap();
            std::fs::copy(e.dir.join("mathlib.dart"), ddir.join("mathlib.dart")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.dart"), ddir.join("client.dart")).unwrap();
            ok(Command::new(&dart).args(["analyze", "--fatal-infos", "mathlib.dart", "client.dart"]).current_dir(&ddir).output().unwrap(), "dart analyze");
            let o = Command::new(&dart).args(["run", "client.dart"]).current_dir(&ddir).env("VOLT_MATHLIB_LIB", format!("{lib_dir}/libmathlib.so")).output().unwrap();
            assert_eq!(ok(o, "dart run client.dart"), MATHLIB_OUT, "Dart ({backend})");
        } else {
            eprintln!("dart isn't installed: skipping the Dart client");
        }
        // Swift: mathlib.swift over the C header, which Swift imports as module Cmathlib
        if let Some(swiftc) = local_tool("swiftc", "--version") {
            let sdir = e.dir.join(format!("swift-{backend}"));
            std::fs::create_dir_all(sdir.join("Cmathlib")).unwrap();
            std::fs::copy(e.dir.join("mathlib.h"), sdir.join("Cmathlib/mathlib.h")).unwrap();
            std::fs::write(sdir.join("Cmathlib/module.modulemap"), "module Cmathlib {\n    header \"mathlib.h\"\n    export *\n}\n").unwrap();
            std::fs::copy(e.dir.join("mathlib.swift"), sdir.join("mathlib.swift")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.swift"), sdir.join("main.swift")).unwrap();
            let o = Command::new(&swiftc).args(["-warnings-as-errors", "-I", "Cmathlib", "mathlib.swift", "main.swift", "-L", &lib_dir, "-lmathlib", "-Xlinker", "-rpath", "-Xlinker", &lib_dir, "-o", "client"]).current_dir(&sdir).output().unwrap();
            ok(o, "swiftc");
            assert_eq!(ok(Command::new(sdir.join("client")).output().unwrap(), "Swift program"), MATHLIB_OUT, "Swift ({backend})");
        } else {
            eprintln!("swiftc isn't installed: skipping the Swift client");
        }
        // Kotlin/Native: cinterop makes the C header package cmathlib; mathlib.kt wraps it. Its own
        // sysroot has an older glibc than the library may have been linked against
        if let Some(konanc) = local_tool("kotlinc-native", "-version") {
            let kdir = e.dir.join(format!("kotlin-{backend}"));
            std::fs::create_dir_all(&kdir).unwrap();
            std::fs::copy(e.dir.join("mathlib.h"), kdir.join("mathlib.h")).unwrap();
            std::fs::write(kdir.join("mathlib.def"), "headers = mathlib.h\npackage = cmathlib\n").unwrap();
            std::fs::copy(e.dir.join("mathlib.kt"), kdir.join("mathlib.kt")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client.kt"), kdir.join("client.kt")).unwrap();
            let k = |tool: &Path, args: &[&str]| Command::new(tool).args(args).current_dir(&kdir).output().unwrap();
            ok(k(&konanc.with_file_name("cinterop"), &["-def", "mathlib.def", "-compiler-option", "-I.", "-o", "mathlib_c"]), "cinterop");
            let link = format!("-L{lib_dir} -lmathlib -rpath {lib_dir} --allow-shlib-undefined");
            let o = k(&konanc, &["mathlib.kt", "client.kt", "-l", "mathlib_c.klib", "-linker-options", &link, "-o", "client"]);
            assert!(!String::from_utf8_lossy(&o.stderr).contains("warning:"), "kotlinc-native warns: {}", String::from_utf8_lossy(&o.stderr));
            ok(o, "kotlinc-native");
            assert_eq!(ok(Command::new(kdir.join("client.kexe")).output().unwrap(), "Kotlin program"), MATHLIB_OUT, "Kotlin ({backend})");
        } else {
            eprintln!("kotlinc-native isn't installed: skipping the Kotlin client");
        }
        // Ruby: the C extension, built against Ruby's headers; client.rb also asserts what it rejects
        match ruby_headers() {
            Some((ruby, hdrs)) => {
                let rdir = e.dir.join(format!("ruby-{backend}"));
                std::fs::create_dir_all(&rdir).unwrap();
                let mut cc = Command::new("cc");
                cc.args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror"]);
                for h in &hdrs {
                    cc.arg("-I").arg(h);
                }
                ok(run(cc.arg(e.dir.join("mathlib_ruby.c")).args(["-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(rdir.join("mathlib.so"))), "cc mathlib_ruby.c");
                let o = Command::new(&ruby).arg("-I").arg(&rdir).arg(Path::new(ROOT).join("tests/interop/client.rb")).output().unwrap();
                assert_eq!(ok(o, "ruby client.rb"), MATHLIB_OUT, "Ruby ({backend})");
            }
            None => eprintln!("ruby (with its headers) isn't installed: skipping the Ruby client"),
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
    std::fs::write(pkg_dir.join("bolt.toml"), "[package]\nname = \"twice\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"volt\", \"shared\", \"static\"]\nbindings = [\"c\", \"python\", \"node\", \"js\", \"ts\", \"lua\", \"ruby\", \"swift\", \"kotlin\"]\n\n[std]\npath = \"STD\"\n".replace("STD", &Path::new(ROOT).join("std").display().to_string())).unwrap();
    std::fs::write(pkg_dir.join("lib/twice.volt"), "export fn twice(x: i32) -> i32 { return x * 2; }\n").unwrap();
    // ~/.local/bin on the PATH, where a downloaded ruby goes
    let path = std::env::var("PATH").unwrap_or_default();
    let path = std::env::var("HOME").map(|h| format!("{h}/.local/bin:{path}")).unwrap_or(path);
    let b = Command::new(env!("CARGO_BIN_EXE_bolt")).arg("build").current_dir(&pkg_dir).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("PATH", &path).output().unwrap();
    assert!(b.status.success(), "bolt build: {}", String::from_utf8_lossy(&b.stderr));
    for f in ["libtwice.so", "libtwice.a", "deps/libtwice.a", "bindings/twice.h", "bindings/twice.py", "bindings/twice_node.c", "bindings/twice.js", "bindings/twice.d.ts", "bindings/twice_lua.c", "bindings/twice_ruby.c", "bindings/twice.swift", "bindings/Ctwice/module.modulemap", "bindings/twice.kt", "bindings/twice.def"] {
        assert!(pkg_dir.join("target/debug").join(f).is_file(), "bolt didn't make target/debug/{f}");
    }
    // the native modules it compiled load as they are, from target/
    let bindings = pkg_dir.join("target/debug/bindings");
    if node_include().is_some() {
        let o = Command::new("node").args(["-e", "console.log(require('./twice.js').twice(21))"]).current_dir(&bindings).output().unwrap();
        assert_eq!(ok(o, "node (bolt's addon)"), "42\n", "bolt's Node addon");
    }
    if lua_include().is_some() {
        let o = Command::new("lua").args(["-e", "package.cpath = 'lua/?.so'; print(require('twice').twice(21))"]).current_dir(&bindings).output().unwrap();
        assert_eq!(ok(o, "lua (bolt's module)"), "42\n", "bolt's Lua module");
    }
    if let Some((ruby, _)) = ruby_headers() {
        let o = Command::new(ruby).args(["-I", "ruby", "-e", "require 'twice'; puts Twice.twice(21)"]).current_dir(&bindings).output().unwrap();
        assert_eq!(ok(o, "ruby (bolt's extension)"), "42\n", "bolt's Ruby extension");
    }

    // what bindings can't express is an error that says why
    let bad = e.dir.join("bad");
    std::fs::create_dir_all(&bad).unwrap();
    std::fs::write(bad.join("bad.volt"), "fn pair() -> (i32, i32) { return (1, 2); }\nexport fn bad_pair(x: (i32, i32)) -> i32 { return x.0; }\n").unwrap();
    let o = e.voltc(&["bindings", "bad", "--pkg", &format!("bad={}", bad.display()), "--lang", "c"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("bad_pair") && err.contains("(i32, i32)"), "{err}");
    for (src, lang, want) in [
        // the names voltc lib adds itself
        ("export struct thing { n: i32; }\nexport fn thing_new() -> thing { return { n: 1 }; }\nexport fn thing_free(t: thing&) -> void {}\n", "c", "makes thing_free itself"),
        ("namespace __export { fn x() -> void {} }\nexport fn one() -> i32 { return 1; }\n", "c", "namespace __export"),
        // a slice of what crosses converted has no owner as a result
        ("use std::string;\nexport fn bad_view(xs: std::string[..]) -> std::string[..] { return xs; }\n", "c", "which nothing would own"),
        // handles in a slice a Python function gives back: nothing would lend them
        ("export struct gadget { n: i32; }\nexport fn bad_cb(f: fn(i32) -> gadget*[..]) -> usize { return f(1).len; }\n", "python", "nothing would lend the handles"),
    ] {
        std::fs::write(bad.join("bad.volt"), src).unwrap();
        let o = e.voltc(&["bindings", "bad", "--pkg", &format!("bad={}", bad.display()), "--lang", lang]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains(want), "{err}");
    }
}

// a slice of slices has a C type of its own (slice_slice_i64), not its elements' name again; slices
// of lent and of nullable handles share one (the same C type), declared once
#[test]
fn bindings_nested_slices() {
    let e = Env::new("nested");
    let dir = e.dir.join("nested");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("nested.volt"), "export fn total(rows: i64[..][..]) -> i64 {\n    var t: i64 = 0;\n    for (r) in rows {\n        for (x) in r {\n            t += x;\n        }\n    }\n    return t;\n}\n\nexport struct thing {\n    n: i64;\n}\n\nexport fn thing_new(n: i64) -> thing {\n    return { n: n };\n}\n\nexport fn sum_lent(xs: thing&[..]) -> i64 {\n    var t: i64 = 0;\n    for (x) in xs {\n        t += x.n;\n    }\n    return t;\n}\n\nexport fn sum_maybe(xs: thing*[..]) -> i64 {\n    var t: i64 = 0;\n    for (x) in xs {\n        if (x != null) {\n            t += x->n;\n        }\n    }\n    return t;\n}\n").unwrap();
    let pkg = format!("nested={}", dir.display());
    ok(e.voltc(&["lib", "nested", "--pkg", &pkg, "--shared", "-o", &e.path("libnested.so")]), "voltc lib nested --shared");
    ok(e.voltc(&["bindings", "nested", "--pkg", &pkg, "--lang", "c", "-o", &e.path("nested.h")]), "voltc bindings nested --lang c");
    std::fs::write(e.dir.join("main.c"), "#include \"nested.h\"\n#include <stdio.h>\n\nint main(void) {\n    int64_t a[] = {1, 2}, b[] = {3};\n    nested_slice_i64 rows[] = {{a, 2}, {b, 1}};\n    printf(\"%lld\\n\", (long long)total((nested_slice_slice_i64){rows, 2}));\n    nested_thing *ts[] = {thing_new(2), thing_new(5)};\n    nested_thing *ms[] = {ts[0], NULL, ts[1]};\n    printf(\"%lld %lld\\n\", (long long)sum_lent((nested_slice_nested_thing){ts, 2}), (long long)sum_maybe((nested_slice_nested_thing){ms, 3}));\n    thing_free(ts[0]);\n    thing_free(ts[1]);\n    return 0;\n}\n").unwrap();
    let rpath = format!("-Wl,-rpath,{}", e.path(""));
    ok(Command::new("cc").args(["-Wall", "-Werror", "main.c", "-I", &e.path(""), "-L", &e.path(""), "-lnested", &rpath, "-o", "main"]).current_dir(&e.dir).output().unwrap(), "cc main.c");
    assert_eq!(ok(Command::new(e.dir.join("main")).output().unwrap(), "main"), "6\n7 7\n");
}

const SHAPES_OUT: &str = "biggest 9 1.5\naccount bea 300\nvisit 301 get 301\nclosed 301 1\ncircle of area 3\ncircle gone\ngrown 27\nsquare 9 square of area 9\nhey!\ntry 4 OVERDRAWN\nopened 25\nclosed 2\n42 hello, volt\nowners 2 ann bobby\nrichest 9 after 6 10\nopened 2 dee\nsquares 4 16 sum 30\njoined a-b-c total 3\nhello, ann; hello, nobody\nnick 1 ann 0\nopen_if 1 1\nclose_if 0 -1\nclose_all 2\nsome 2\nrows 6\narrays 12 13 11 2.5 1.5 2 3 4\ntagged 41 5 20 7 8 127\nlists closed 7\ncircle gone\n";

#[test]
fn bindings_shapes() {
    // what every language calls beyond the plain shapes: a generic's instances, a struct that owns text
    // held by a handle with its methods, owned values passed in, a trait implemented on either side,
    // closures taking and giving text and handles, closures given back. The library is a leak-checked
    // build, and leak_report.c (or the client) prints how many of its allocations are live when the client is done
    let e = Env::new("shapes");
    let pkg = "shapelib=shapelib/lib";
    for (lang, file) in [("c", "shapelib.h"), ("cpp", "shapelib.hpp"), ("rust", "shapelib.rs"), ("zig", "shapelib.zig"), ("go", "shapelib.go"), ("python", "shapelib.py"), ("pyi", "shapelib.pyi"), ("java", "shapelib.java"), ("node", "shapelib_node.c"), ("js", "shapelib.js"), ("ts", "shapelib.d.ts"), ("lua", "shapelib_lua.c"), ("ruby", "shapelib_ruby.c"), ("dart", "shapelib.dart"), ("swift", "shapelib.swift"), ("kotlin", "shapelib.kt")] {
        ok(e.voltc(&["bindings", "shapelib", "--pkg", pkg, "--lang", lang, "-o", &e.path(file)]), &format!("voltc bindings --lang {lang}"));
    }
    let konanc = local_tool("kotlinc-native", "-version");
    if konanc.is_none() {
        eprintln!("kotlinc-native isn't installed: skipping the Kotlin shapes client");
    }
    // Rust: client_shapes.rs next to its shapelib.rs module, with the leak report as an object
    std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.rs"), e.dir.join("client_shapes.rs")).unwrap();
    ok(run(Command::new("cc").args(["-c", "leak_report.c", "-o"]).arg(e.dir.join("leak_report.o"))), "cc -c leak_report.c");
    for backend in ["c", "llvm"] {
        let lib = e.path(backend);
        std::fs::create_dir_all(e.dir.join(backend)).unwrap();
        ok(e.voltc(&["lib", "shapelib", "--pkg", pkg, "--shared", "--leak-check", "--backend", backend, "-o", &format!("{lib}/libshapelib.so")]), "voltc lib --shared");
        let rpath = format!("-Wl,-rpath,{lib}");
        for (cc, std, client) in [("cc", "-std=c11", "client_shapes.c"), ("c++", "-std=c++17", "client_shapes.cpp")] {
            let bin = e.dir.join(format!("{backend}_{cc}"));
            ok(run(Command::new(cc).args([std, "-Wall", "-Werror", client, "leak_report.c", "-I", &e.path(""), "-L", &lib, "-lshapelib", &rpath, "-o"]).arg(&bin)), &format!("{cc} {client}"));
            let o = Command::new(&bin).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "{client} ({backend}): the library's allocations at exit");
            assert_eq!(ok(o, client), SHAPES_OUT, "{client} ({backend})");
        }
        let bin = e.dir.join(format!("{backend}_rs"));
        ok(run(Command::new("rustc").arg(e.dir.join("client_shapes.rs")).args(["--edition", "2021", "-L", &lib, "-l", "shapelib", "-C"]).arg(format!("link-arg={}", e.path("leak_report.o"))).args(["-C", &format!("link-arg={rpath}"), "-o"]).arg(&bin)), "rustc client_shapes.rs");
        let o = Command::new(&bin).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.rs ({backend}): the library's allocations at exit");
        assert_eq!(ok(o, "client_shapes.rs"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "client_shapes.rs ({backend})");
        // Zig: client_shapes.zig next to its shapelib.zig, printing to stderr (the leak report last)
        if let Some(zig) = zig() {
            for f in ["client_shapes.zig", "leak_report.c"] {
                std::fs::copy(Path::new(ROOT).join("tests/interop").join(f), e.dir.join(f)).unwrap();
            }
            let mut target = Vec::new();
            if cfg!(target_os = "linux") {
                target = vec!["-target".to_string(), format!("{}-linux-gnu", std::env::consts::ARCH)];
            }
            let z = Command::new(zig).args(["run", "client_shapes.zig", "leak_report.c"]).args(&target).args(["-lc", "-L", &lib, "-lshapelib"]).current_dir(&e.dir).env("LD_LIBRARY_PATH", &lib).output().unwrap();
            assert!(z.status.success(), "zig run client_shapes.zig: {}", String::from_utf8_lossy(&z.stderr));
            assert_eq!(String::from_utf8_lossy(&z.stderr), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}volt live: 0\n"), "client_shapes.zig ({backend})");
        } else {
            eprintln!("zig isn't installed: skipping the Zig shapes client");
        }
        // Java (22 or later): ClientShapes.java next to its shapelib.java, through the FFM API (the
        // leak report from the library's volt_live_allocs, on stderr)
        match jdk_bin() {
            Some(bin) => {
                let jdir = e.dir.join(format!("java-{backend}"));
                std::fs::create_dir_all(&jdir).unwrap();
                std::fs::copy(e.dir.join("shapelib.java"), jdir.join("shapelib.java")).unwrap();
                std::fs::copy(Path::new(ROOT).join("tests/interop/ClientShapes.java"), jdir.join("ClientShapes.java")).unwrap();
                ok(Command::new(bin.join("javac")).args(["-Xlint:all", "-Werror", "-d", "classes", "shapelib.java", "ClientShapes.java"]).current_dir(&jdir).output().unwrap(), "javac ClientShapes.java");
                let o = Command::new(bin.join("java")).args(["--enable-native-access=ALL-UNNAMED", "-cp", "classes", "ClientShapes"]).current_dir(&jdir).env("LD_LIBRARY_PATH", &lib).output().unwrap();
                assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "ClientShapes.java ({backend}): the library's allocations at exit");
                assert_eq!(ok(o, "java ClientShapes"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "ClientShapes.java ({backend})");
            }
            None => eprintln!("no JDK 22 or later (javac): skipping the Java shapes client"),
        }
        // C#: a console project around the generated shapelib.cs, the leak report on stderr
        if let Some(dotnet) = local_tool("dotnet", "--version") {
            ok(e.voltc(&["bindings", "shapelib", "--pkg", pkg, "--lang", "csharp", "-o", &e.path("shapelib.cs")]), "voltc bindings --lang csharp");
            let v = String::from_utf8_lossy(&Command::new(&dotnet).arg("--version").output().unwrap().stdout).trim().to_string();
            let major = v.split('.').next().unwrap_or("10").to_string();
            let proj = e.dir.join(format!("cs-{backend}"));
            std::fs::create_dir_all(&proj).unwrap();
            std::fs::copy(e.dir.join("shapelib.cs"), proj.join("shapelib.cs")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.cs"), proj.join("client_shapes.cs")).unwrap();
            std::fs::write(proj.join("Client.csproj"), format!("<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n    <TargetFramework>net{major}.0</TargetFramework>\n    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>\n    <Nullable>enable</Nullable>\n    <InvariantGlobalization>true</InvariantGlobalization>\n    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>\n  </PropertyGroup>\n</Project>\n")).unwrap();
            let o = Command::new(&dotnet).args(["run", "--nologo"]).current_dir(&proj).env("LD_LIBRARY_PATH", &lib).env("DOTNET_CLI_TELEMETRY_OPTOUT", "1").env("DOTNET_NOLOGO", "1").env("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1").output().unwrap();
            let err = String::from_utf8_lossy(&o.stderr).to_string();
            let out = ok(o, "dotnet run client_shapes.cs");
            assert_eq!(err, "volt live: 0\n", "client_shapes.cs ({backend}): the library's allocations at exit");
            assert_eq!(out, format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "client_shapes.cs ({backend})");
        } else {
            eprintln!("dotnet isn't installed: skipping the C# shapes client");
        }
        // Python: client_shapes.py with shapelib.py, printing the library's leak report itself (and
        // after the rest, what only Python checks: callbacks' exceptions, what Volt can't take)
        let py = Command::new("python3").arg(Path::new(ROOT).join("tests/interop/client_shapes.py")).env("PYTHONPATH", e.path("")).env("VOLT_SHAPELIB_LIB", format!("{lib}/libshapelib.so")).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&py.stderr), "volt live: 0\n", "client_shapes.py ({backend}): the library's allocations at exit");
        let tail = "raised ValueError ValueError ValueError ValueError\nwrong type TypeError\nwrong length ValueError ValueError\nrefused ValueError ValueError ValueError\nkept ValueError ann 5\nfatal 101 True\n";
        assert_eq!(ok(py, "python3 client_shapes.py"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}{tail}"), "client_shapes.py ({backend})");
        // Go: a module with the generated cgo package; the client prints the leak report to stderr
        // itself (a Go program's exit runs no C destructors)
        if Command::new("go").arg("version").output().is_ok_and(|o| o.status.success()) {
            let gdir = e.dir.join(format!("go-{backend}"));
            std::fs::create_dir_all(gdir.join("shapelib")).unwrap();
            std::fs::copy(e.dir.join("shapelib.go"), gdir.join("shapelib/shapelib.go")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.go"), gdir.join("main.go")).unwrap();
            std::fs::write(gdir.join("go.mod"), "module client\n\ngo 1.22\n").unwrap();
            let flags = format!("-L{lib} {rpath}");
            let go = |args: &[&str]| Command::new("go").args(args).current_dir(&gdir).env("CGO_LDFLAGS", &flags).env("GOFLAGS", "-mod=mod").env("GOPROXY", "off").output().unwrap();
            let unformatted = ok(Command::new("gofmt").args(["-l", "."]).current_dir(&gdir).output().unwrap(), "gofmt -l");
            assert_eq!(unformatted, "", "gofmt would change these ({backend})");
            ok(go(&["vet", "./..."]), "go vet (shapes)");
            ok(go(&["build", "-o", "client", "."]), "go build (shapes)");
            let o = Command::new(gdir.join("client")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.go ({backend}): the library's allocations at exit");
            assert_eq!(ok(o, "client_shapes.go"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "client_shapes.go ({backend})");
        } else {
            eprintln!("go isn't installed: skipping the Go shapes client");
        }
        // JavaScript: the Node-API addon, with the leak report linked into it (printed when node
        // exits, after the objects still held are finalized)
        match node_include() {
            Some(inc) => {
                let ndir = e.dir.join(format!("node-{backend}"));
                std::fs::create_dir_all(&ndir).unwrap();
                std::fs::copy(e.dir.join("shapelib.js"), ndir.join("shapelib.js")).unwrap();
                std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.js"), ndir.join("client_shapes.js")).unwrap();
                ok(run(Command::new("cc").args(["-shared", "-fPIC", "-I", &inc]).arg(e.dir.join("shapelib_node.c")).args(["leak_report.c", "-L", &lib, "-lshapelib", &rpath, "-o"]).arg(ndir.join("shapelib.node"))), "cc shapelib_node.c");
                let o = Command::new("node").arg("client_shapes.js").current_dir(&ndir).output().unwrap();
                assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.js ({backend}): the library's allocations at exit");
                assert_eq!(ok(o, "node client_shapes.js"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "client_shapes.js ({backend})");
                // Bun runs the same addon (it exits without running the library's destructors, so
                // without the leak report)
                if Command::new("bun").arg("--version").output().is_ok_and(|o| o.status.success()) {
                    let b = Command::new("bun").arg("client_shapes.js").current_dir(&ndir).output().unwrap();
                    assert_eq!(ok(b, "bun client_shapes.js"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "bun client_shapes.js ({backend})");
                }
            }
            None => eprintln!("node isn't installed (or has no headers): skipping the JavaScript shapes client"),
        }
        // Lua: the C module with the leak report in it (it runs when lua_close unloads the module,
        // after the finalizers), and client_shapes.lua
        if let Some(inc) = lua_include() {
            let ldir = e.dir.join(format!("lua-{backend}"));
            std::fs::create_dir_all(&ldir).unwrap();
            ok(run(Command::new("cc").args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-I", inc]).arg(e.dir.join("shapelib_lua.c")).args(["leak_report.c", "-I", &e.path(""), "-L", &lib, "-lshapelib", &rpath, "-o"]).arg(ldir.join("shapelib.so"))), "cc shapelib_lua.c");
            let o = Command::new("lua").arg(Path::new(ROOT).join("tests/interop/client_shapes.lua")).env("LUA_CPATH", ldir.join("?.so")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.lua ({backend}): the library's allocations at exit");
            assert_eq!(ok(o, "lua client_shapes.lua"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "client_shapes.lua ({backend})");
        } else {
            eprintln!("lua (5.4 or later, with its headers) isn't installed: skipping the Lua shapes client");
        }
        // Ruby: client_shapes.rb with the C extension, which has the leak report linked in (it runs
        // at exit, once Ruby has freed its objects); after the rest, what only Ruby checks
        match ruby_headers() {
            Some((ruby, hdrs)) => {
                let rdir = e.dir.join(format!("ruby-{backend}"));
                std::fs::create_dir_all(&rdir).unwrap();
                ok(run(ruby_ext(&hdrs, &e.dir.join("shapelib_ruby.c"), &lib, "shapelib").arg(rdir.join("shapelib.so"))), "cc shapelib_ruby.c");
                let o = Command::new(&ruby).arg("-I").arg(&rdir).arg(Path::new(ROOT).join("tests/interop/client_shapes.rb")).output().unwrap();
                assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.rb ({backend}): the library's allocations at exit");
                let tail = "raised ArgumentError ArgumentError ArgumentError ArgumentError\nwrong type TypeError TypeError\nrefused RuntimeError ArgumentError ArgumentError\nin use RuntimeError RuntimeError\nkept RuntimeError ann 5\nlent after RuntimeError\nshrinking closed\nclosed anyway ArgumentError\nbreak 7\nfatal 101 true\n";
                assert_eq!(ok(o, "ruby client_shapes.rb"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}{tail}"), "client_shapes.rb ({backend})");
            }
            None => eprintln!("ruby (with its headers) isn't installed: skipping the Ruby shapes client"),
        }
        // Dart: client_shapes.dart next to its shapelib.dart (dart analyze checks both), printing the
        // library's leak report itself, and after the rest what only Dart checks: callbacks'
        // exceptions, what Volt can't take, a callback that has to give a handle and throws
        if let Some(dart) = local_tool("dart", "--version") {
            let ddir = e.dir.join(format!("dart-{backend}"));
            std::fs::create_dir_all(&ddir).unwrap();
            std::fs::copy(e.dir.join("shapelib.dart"), ddir.join("shapelib.dart")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.dart"), ddir.join("client_shapes.dart")).unwrap();
            if backend == "c" {
                ok(Command::new(&dart).args(["analyze", "--fatal-infos", "shapelib.dart", "client_shapes.dart"]).current_dir(&ddir).output().unwrap(), "dart analyze (shapes)");
            }
            let o = Command::new(&dart).args(["run", "client_shapes.dart"]).current_dir(&ddir).env("VOLT_SHAPELIB_LIB", format!("{lib}/libshapelib.so")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.dart ({backend}): the library's allocations at exit");
            let tail = "raised StateError StateError StateError StateError\nrefused StateError StateError StateError StateError StateError StateError StateError\nkept StateError ann 5\nfatal 101 true\n";
            assert_eq!(ok(o, "dart run client_shapes.dart"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}{tail}"), "client_shapes.dart ({backend})");
        } else {
            eprintln!("dart isn't installed: skipping the Dart shapes client");
        }
        // Swift: shapelib.swift over the C header (module Cshapelib), with the leak report linked in;
        // then what it refuses, each a failed precondition
        if let Some(swiftc) = local_tool("swiftc", "--version") {
            let sdir = e.dir.join(format!("swift-{backend}"));
            std::fs::create_dir_all(sdir.join("Cshapelib")).unwrap();
            std::fs::copy(e.dir.join("shapelib.h"), sdir.join("Cshapelib/shapelib.h")).unwrap();
            std::fs::write(sdir.join("Cshapelib/module.modulemap"), "module Cshapelib {\n    header \"shapelib.h\"\n    export *\n}\n").unwrap();
            std::fs::copy(e.dir.join("shapelib.swift"), sdir.join("shapelib.swift")).unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.swift"), sdir.join("main.swift")).unwrap();
            let o = Command::new(&swiftc).args(["-warnings-as-errors", "-I", "Cshapelib", "shapelib.swift", "main.swift"]).arg(e.dir.join("leak_report.o")).args(["-L", &lib, "-lshapelib", "-Xlinker", "-rpath", "-Xlinker", &lib, "-o", "client"]).current_dir(&sdir).output().unwrap();
            ok(o, "swiftc client_shapes.swift");
            let o = Command::new(sdir.join("client")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.swift ({backend}): the library's allocations at exit");
            assert_eq!(ok(o, "client_shapes.swift"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}thrown Odd()\n"), "client_shapes.swift ({backend})");
            for (what, msg) in [("busy", "account can't be closed: a running Volt call holds it"), ("held", "account can't be given away: a running Volt call holds it"), ("twice", "account is given twice"), ("lent", "account is lent by Volt: it isn't Swift's to give")] {
                let o = Command::new(sdir.join("client")).arg(what).output().unwrap();
                let err = String::from_utf8_lossy(&o.stderr);
                assert!(!o.status.success() && err.contains(msg), "client_shapes.swift {what} ({backend}): {err}");
            }
            // swiftedge: the shapes shapelib doesn't have (rarer callbacks, a trait with E!T and handles,
            // lists of enums and optionals, E!T of a list, a handle and a trait, names Swift has)
            let edir = e.dir.join(format!("swiftedge-{backend}"));
            std::fs::create_dir_all(edir.join("Cswiftedge")).unwrap();
            let epkg = "swiftedge=swiftedge/lib";
            for (lang, file) in [("c", "Cswiftedge/swiftedge.h"), ("swift", "swiftedge.swift")] {
                ok(e.voltc(&["bindings", "swiftedge", "--pkg", epkg, "--lang", lang, "-o", &edir.join(file).display().to_string()]), &format!("voltc bindings swiftedge --lang {lang}"));
            }
            let elib = edir.display().to_string();
            ok(e.voltc(&["lib", "swiftedge", "--pkg", epkg, "--shared", "--leak-check", "--backend", backend, "-o", &format!("{elib}/libswiftedge.so")]), "voltc lib swiftedge");
            std::fs::write(edir.join("Cswiftedge/module.modulemap"), "module Cswiftedge {\n    header \"swiftedge.h\"\n    export *\n}\n").unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client_swiftedge.swift"), edir.join("main.swift")).unwrap();
            let o = Command::new(&swiftc).args(["-warnings-as-errors", "-I", "Cswiftedge", "swiftedge.swift", "main.swift"]).arg(e.dir.join("leak_report.o")).args(["-L", &elib, "-lswiftedge", "-Xlinker", "-rpath", "-Xlinker", &elib, "-o", "client"]).current_dir(&edir).output().unwrap();
            ok(o, "swiftc client_swiftedge.swift");
            let o = Command::new(edir.join("client")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_swiftedge.swift ({backend}): the library's allocations at exit");
            let want = "names 40 6\ncount_text 3 sum_things 9\nslice_cb 3 [9, 2, 3]\ncstr_cb 1 -1\nstr_cb 3\nenum_cb BLUE\npoint_cb 12.0\nstr_result_cb 4 -1 Odd()\nany_cb 2 WORSE Odd()\nswallow got 1 Odd() caught\nlent_ptr_cb 4 -1\nrun_counter 1010 2\ngive_counter 5\nvolts 3 t4 volt WORSE\nrun volts 7 give volts 10\nnamer n4 8 3 4\ncolors [\"BLUE\", \"RED\"] 11\nmaybes [\"5\", \"nil\"] 101\nopt_point 2.0 1.0 true\nopt_color GREEN nil\nmaybe_str yes nil\nenum_slice 2\nlisty [\"a\"] NOPE\nmk_thing 9 WORSE\nmk_counter 101 NOPE\ntexts_in 2 maybe_thing 4 -1\n";
            assert_eq!(ok(o, "client_swiftedge.swift"), want, "client_swiftedge.swift ({backend})");
        } else {
            eprintln!("swiftc isn't installed: skipping the Swift shapes client");
        }
        // Kotlin/Native: cinterop makes the C header package cshapelib, and client_shapes.kt with the
        // generated shapelib.kt is compiled once, with the leak report linked in (each backend's
        // library found through LD_LIBRARY_PATH); after SHAPES_OUT it prints what only it checks
        if let Some(konanc) = &konanc {
            let kdir = e.dir.join("kotlin");
            if backend == "c" {
                std::fs::create_dir_all(&kdir).unwrap();
                for f in ["shapelib.h", "shapelib.kt"] {
                    std::fs::copy(e.dir.join(f), kdir.join(f)).unwrap();
                }
                std::fs::copy(Path::new(ROOT).join("tests/interop/client_shapes.kt"), kdir.join("client_shapes.kt")).unwrap();
                std::fs::write(kdir.join("shapelib.def"), "headers = shapelib.h\npackage = cshapelib\n").unwrap();
                let k = |tool: &Path, args: &[&str]| Command::new(tool).args(args).current_dir(&kdir).output().unwrap();
                ok(k(&konanc.with_file_name("cinterop"), &["-def", "shapelib.def", "-compiler-option", "-I.", "-o", "shapelib_c"]), "cinterop shapelib.def");
                let link = format!("{} -L{lib} -lshapelib --allow-shlib-undefined", e.path("leak_report.o"));
                let o = k(konanc, &["shapelib.kt", "client_shapes.kt", "-l", "shapelib_c.klib", "-linker-options", &link, "-o", "client"]);
                assert!(!String::from_utf8_lossy(&o.stderr).contains("warning:"), "kotlinc-native warns: {}", String::from_utf8_lossy(&o.stderr));
                ok(o, "kotlinc-native client_shapes.kt");
            }
            let o = Command::new(kdir.join("client.kexe")).env("LD_LIBRARY_PATH", &lib).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_shapes.kt ({backend}): the library's allocations at exit");
            let tail = "raised shout twice name\nrefused this account is in use by a running call; this account is given twice; this account is closed\nkept ann 5\nclosed this account is closed\n";
            assert_eq!(ok(o, "client_shapes.kt"), format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}{tail}"), "client_shapes.kt ({backend})");
        }
    }
    // the TypeScript types: checked by tsc when it's installed, else parsed (node 23.2+ strips them)
    if Command::new("tsc").arg("--version").output().is_ok_and(|o| o.status.success()) {
        ok(Command::new("tsc").args(["--noEmit", "--strict", "--target", "es2022", "shapelib.d.ts"]).current_dir(&e.dir).output().unwrap(), "tsc shapelib.d.ts");
    } else if node_include().is_some() {
        let parse = "const m = require('module'); if (m.stripTypeScriptTypes) { m.stripTypeScriptTypes(require('fs').readFileSync('shapelib.d.ts', 'utf8')); }";
        ok(Command::new("node").args(["-e", parse]).current_dir(&e.dir).output().unwrap(), "parse shapelib.d.ts");
    }
    let parse = format!("import ast; ast.parse(open({:?}).read())", e.path("shapelib.pyi"));
    ok(run(Command::new("python3").args(["-c", &parse])), "parse shapelib.pyi");
    // Python: optional text and nullable handles in slices, from a package of its own (shapelib's
    // other clients don't call these)
    let opt = e.dir.join("pyopt");
    std::fs::create_dir_all(&opt).unwrap();
    std::fs::write(opt.join("pyopt.volt"), "export struct thing {\n    n: i64;\n}\n\nexport fn thing_new(n: i64) -> thing {\n    return { n: n };\n}\n\nexport fn count_text(xs: str?[..]) -> i64 {\n    var t: i64 = 0;\n    for (x) in xs {\n        val s = x ?? continue;\n        t += @cast<i64>(s.len);\n    }\n    return t;\n}\n\nexport fn sum_things(xs: thing*[..]) -> i64 {\n    var t: i64 = 0;\n    for (x) in xs {\n        if (x != null) {\n            t += x->n;\n        }\n    }\n    return t;\n}\n").unwrap();
    let opkg = format!("pyopt={}", opt.display());
    ok(e.voltc(&["bindings", "pyopt", "--pkg", &opkg, "--lang", "python", "-o", &e.path("pyopt.py")]), "voltc bindings pyopt --lang python");
    ok(e.voltc(&["lib", "pyopt", "--pkg", &opkg, "--shared", "--leak-check", "-o", &e.path("libpyopt.so")]), "voltc lib pyopt --shared");
    let check = "import ctypes, pyopt as p\nprint(p.count_text(['ab', None, 'c']), p.sum_things([p.thing(2), None, p.thing(5)]))\nprint(ctypes.c_size_t.in_dll(p._lib, 'volt_live_allocs').value)\n";
    let o = Command::new("python3").args(["-c", check]).env("PYTHONPATH", e.path("")).env("VOLT_PYOPT_LIB", e.path("libpyopt.so")).output().unwrap();
    assert_eq!(ok(o, "python3 (pyopt)"), "3 7\n0\n", "Python: optionals of text and handles in slices");
    // Ruby: the same, nil for none (the leak report linked into the extension)
    if let Some((ruby, hdrs)) = ruby_headers() {
        ok(e.voltc(&["bindings", "pyopt", "--pkg", &opkg, "--lang", "ruby", "-o", &e.path("pyopt_ruby.c")]), "voltc bindings pyopt --lang ruby");
        let rdir = e.dir.join("ruby-pyopt");
        std::fs::create_dir_all(&rdir).unwrap();
        ok(run(ruby_ext(&hdrs, &e.dir.join("pyopt_ruby.c"), &e.path(""), "pyopt").arg(rdir.join("pyopt.so"))), "cc pyopt_ruby.c");
        let o = Command::new(&ruby).arg("-I").arg(&rdir).args(["-e", "require 'pyopt'; puts \"#{Pyopt.count_text(['ab', nil, 'c'])} #{Pyopt.sum_things([Pyopt::Thing.new(2), nil, Pyopt::Thing.new(5)])}\""]).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "Ruby (pyopt): the library's allocations at exit");
        assert_eq!(ok(o, "ruby (pyopt)"), "3 7\n", "Ruby: optionals of text and handles in slices");
        // what shapelib doesn't have: client_moreshapes.rb with moreshapes (a trait object Volt keeps
        // past the call, handles given to a callback, a str a callback gives, ...)
        let mpkg = "moreshapes=moreshapes/lib";
        ok(e.voltc(&["bindings", "moreshapes", "--pkg", mpkg, "--lang", "ruby", "-o", &e.path("moreshapes_ruby.c")]), "voltc bindings moreshapes --lang ruby");
        ok(e.voltc(&["lib", "moreshapes", "--pkg", mpkg, "--shared", "--leak-check", "-o", &e.path("libmoreshapes.so")]), "voltc lib moreshapes --shared");
        ok(run(ruby_ext(&hdrs, &e.dir.join("moreshapes_ruby.c"), &e.path(""), "moreshapes").arg(rdir.join("moreshapes.so"))), "cc moreshapes_ruby.c");
        let o = Command::new(&ruby).arg("-I").arg(&rdir).arg(Path::new(ROOT).join("tests/interop/client_moreshapes.rb")).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_moreshapes.rb: the library's allocations at exit");
        let want = "measure 70 tag sizer\nsizer closed\neach 0,1,2 gone 4\nstopped stop gone 7\nlabel pos neg\nslice 6\nresult 5 -1\nmaybe yes nil cstr 5\nlist [1, nil]\ngetter 9 [9]\nbig [5, 7]\nfixed 1020 RuntimeError\nbad ArgumentError TypeError\nclosed meanwhile RuntimeError RuntimeError gone 14\n";
        assert_eq!(ok(o, "ruby client_moreshapes.rb"), want, "client_moreshapes.rb");
    }
    // Dart: what shapelib's clients don't call (optional text and nullable handles in slices,
    // callbacks giving a str and a reference or taking a slice, parameters named like the
    // wrappers' own locals, a doc comment of two lines), from a package of its own
    if let Some(dart) = local_tool("dart", "--version") {
        let more = e.dir.join("dartmore");
        std::fs::create_dir_all(&more).unwrap();
        let src = r#"export struct thing {
    n: i64;
}

export fn thing_new(n: i64) -> thing {
    return { n: n };
}

export fn count_text(xs: str?[..]) -> i64 {
    var t: i64 = 0;
    for (x) in xs {
        val s = x ?? continue;
        t += @cast<i64>(s.len);
    }
    return t;
}

export fn sum_things(xs: thing*[..]) -> i64 {
    var t: i64 = 0;
    for (x) in xs {
        if (x != null) {
            t += x->n;
        }
    }
    return t;
}

export fn label(f: fn(i64) -> str, x: i64) -> i64 {
    return @cast<i64>(f(x).len);
}

export fn pick(a: thing&, f: fn(thing&) -> thing&) -> i64 {
    return f(a).n;
}

// a callback taking a slice,
// and text parameters named v and r
export fn total(f: fn(i64[..]) -> i64, v: str, r: str) -> i64 {
    val xs: i64[] = { 1, 2, 3 };
    return f(xs[..]) + @cast<i64>(v.len) + @cast<i64>(r.len);
}

export fn run(call: fn(i64) -> i64) -> i64 {
    return call(4);
}
"#;
        std::fs::write(more.join("dartmore.volt"), src).unwrap();
        let mpkg = format!("dartmore={}", more.display());
        let at = |f: &str| more.join(f).display().to_string();
        ok(e.voltc(&["bindings", "dartmore", "--pkg", &mpkg, "--lang", "dart", "-o", &at("dartmore.dart")]), "voltc bindings dartmore --lang dart");
        ok(e.voltc(&["lib", "dartmore", "--pkg", &mpkg, "--shared", "--leak-check", "-o", &at("libdartmore.so")]), "voltc lib dartmore --shared");
        let client = "import 'dart:ffi';\nimport 'dart:io';\n\nimport 'dartmore.dart';\n\nvoid main() {\n  final a = thing(2), b = thing(5);\n  print('${count_text(['ab', null, 'c'])} ${sum_things([a, null, b])} ${label((x) => 'n$x', 42)} ${pick(a, (t) => t)} ${total((xs) => xs.reduce((x, y) => x + y), 'ab', 'c')} ${run((x) => x + 1)}');\n  a.close();\n  b.close();\n  print(DynamicLibrary.open(Platform.environment['VOLT_DARTMORE_LIB']!).lookup<Size>('volt_live_allocs').value);\n}\n";
        std::fs::write(more.join("more.dart"), client).unwrap();
        ok(Command::new(&dart).args(["analyze", "--fatal-infos", "dartmore.dart", "more.dart"]).current_dir(&more).output().unwrap(), "dart analyze (dartmore)");
        let o = Command::new(&dart).args(["run", "more.dart"]).current_dir(&more).env("VOLT_DARTMORE_LIB", at("libdartmore.so")).output().unwrap();
        assert_eq!(ok(o, "dart run more.dart"), "3 7 3 2 9 5\n0\n", "Dart: optionals in slices, callbacks giving a str and a reference or taking a slice");
    }
    // the model has the trait, and how a fn takes its object
    let json = ok(e.voltc(&["bindings", "shapelib", "--pkg", pkg, "--lang", "json"]), "voltc bindings --lang json");
    for want in [r#"{"kind":"trait","name":"shape","c_name":"shapelib_shape","table":"shapelib_shape_vt""#, r#"{"kind":"object","trait":"shape","owned":false}"#, r#""name":"biggest_i32""#, r#""class":"account","method":"deposit""#] {
        assert!(json.contains(want), "the JSON model lacks {want}:\n{json}");
    }
}

/// Kotlin/Native calls what shapelib's clients don't (ktshapes/lib): the library leak-checked on both
/// backends, client_ktshapes.kt compiled once (each backend's library found through LD_LIBRARY_PATH)
#[test]
fn bindings_kotlin_shapes() {
    let Some(konanc) = local_tool("kotlinc-native", "-version") else {
        eprintln!("kotlinc-native isn't installed: skipping the Kotlin ktshapes client");
        return;
    };
    let e = Env::new("ktshapes");
    let pkg = "ktshapes=ktshapes/lib";
    for (lang, file) in [("c", "ktshapes.h"), ("kotlin", "ktshapes.kt")] {
        ok(e.voltc(&["bindings", "ktshapes", "--pkg", pkg, "--lang", lang, "-o", &e.path(file)]), &format!("voltc bindings ktshapes --lang {lang}"));
    }
    ok(run(Command::new("cc").args(["-c", "leak_report.c", "-o"]).arg(e.dir.join("leak_report.o"))), "cc -c leak_report.c");
    std::fs::copy(Path::new(ROOT).join("tests/interop/client_ktshapes.kt"), e.dir.join("client_ktshapes.kt")).unwrap();
    std::fs::write(e.dir.join("ktshapes.def"), "headers = ktshapes.h\npackage = cktshapes\n").unwrap();
    let k = |tool: &Path, args: &[&str]| Command::new(tool).args(args).current_dir(&e.dir).output().unwrap();
    ok(k(&konanc.with_file_name("cinterop"), &["-def", "ktshapes.def", "-compiler-option", "-I.", "-o", "ktshapes_c"]), "cinterop ktshapes.def");
    for backend in ["c", "llvm"] {
        let lib = e.path(backend);
        std::fs::create_dir_all(e.dir.join(backend)).unwrap();
        ok(e.voltc(&["lib", "ktshapes", "--pkg", pkg, "--shared", "--leak-check", "--backend", backend, "-o", &format!("{lib}/libktshapes.so")]), "voltc lib ktshapes --shared");
        if backend == "c" {
            let link = format!("{} -L{lib} -lktshapes --allow-shlib-undefined", e.path("leak_report.o"));
            let o = k(&konanc, &["ktshapes.kt", "client_ktshapes.kt", "-l", "ktshapes_c.klib", "-linker-options", &link, "-o", "client"]);
            assert!(!String::from_utf8_lossy(&o.stderr).contains("warning:"), "kotlinc-native warns: {}", String::from_utf8_lossy(&o.stderr));
            ok(o, "kotlinc-native client_ktshapes.kt");
        }
        let o = Command::new(e.dir.join("client.kexe")).env("LD_LIBRARY_PATH", &lib).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr), "volt live: 0\n", "client_ktshapes.kt ({backend}): the library's allocations at exit");
        assert_eq!(ok(o, "client_ktshapes.kt"), "measure 50 kotlin\nsizer gone\nfixed 50 fixed\neach [0, 1, 2]\nfailed each 8\nclose_ 700 7\nshut\nlabel n7\nslice 6\nresult 5 9\nmaybe yes null\ncstr 5\nsome [1, null]\ngetter 8\nbig [5, 9]\nlend 8\ngive 7\nrec 14\nbumped 2 9 ab tag BLUE 1\nmade 6\ntotal2 6\ntext 3\nblues 2\nfirst_two [4, 5]\nmaybe_get 5 -1\nslice_back 3\nstr_result 4 -1 -1\ntext_in 4\nlist_or [a] BAD\nsizer_or fixed\ngone 18\n", "client_ktshapes.kt ({backend})");
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

/// Volt calls Python through the interop/python package: a bolt package depends on it and nothing
/// else (its build file finds Python's flags), on both backends
#[test]
fn python_package() {
    if !Command::new("python3-config").arg("--includes").output().is_ok_and(|o| o.status.success()) {
        eprintln!("python3-config isn't installed: skipping the python package");
        return;
    }
    let e = Env::new("python");
    let app = e.dir.join("py_app");
    copy_dir(&Path::new(ROOT).join("tests/interop/py_app/src"), &app.join("src"));
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"py_app\"\nversion = \"0.1.0\"\n\n[dependencies]\npython = {{ path = \"{}\" }}\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("interop/python").display(), Path::new(ROOT).join("std").display())).unwrap();
    let want = "sqrt 1.4142 factorial 3628800\njson \"volt\" and false\nhi volt, hi volt\nlist [0, 1, 4, 9, 16] len 5\nitem 9\nobjects 5 true 4\ncaught EXCEPTION(ZeroDivisionError: division by zero)\nnone true\nthread 5050\n";
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["run", "-q", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), want, "Volt calls Python ({backend})");
    }
}

/// Volt calls Java through the interop/java package: the JVM started in the program (JNI's
/// invocation API), static and instance methods, the JDK's classes and an exception, on both backends
#[test]
fn java_package() {
    let Some(bin) = jdk_bin() else {
        eprintln!("a JDK 22 or later isn't installed: skipping the java package");
        return;
    };
    let e = Env::new("java");
    let app = e.dir.join("java_app");
    let fx = Path::new(ROOT).join("tests/interop/java_app");
    copy_dir(&fx.join("src"), &app.join("src"));
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"java_app\"\nversion = \"0.1.0\"\n\n[dependencies]\njava = {{ path = \"{}\" }}\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("interop/java").display(), Path::new(ROOT).join("std").display())).unwrap();
    let classes = e.dir.join("classes");
    ok(run(Command::new(bin.join("javac")).arg("-d").arg(&classes).arg(fx.join("java/Counter.java"))), "javac");
    let want = "add 42\nHELLO, VOLT\nbump 15 half 7.5\nobject volt=15 equal true\nlist true [x]\nnanos true\nmax 9 sqrt 1.5\nbuilt 42\ncaught THROWN(java.lang.ArithmeticException: / by zero)\nmissing true\nnull false true THROWN(java.lang.NullPointerException: length on null)\n";
    for backend in ["c", "llvm"] {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("JAVA_APP_CLASSES", &classes);
        // a JDK found through ~/.local: the build file finds it through $JAVA_HOME
        if let Some(home) = bin.parent().filter(|h| !h.as_os_str().is_empty()) {
            c.env("JAVA_HOME", home);
        }
        let o = c.output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), want, "Volt calls Java ({backend})");
    }
}

/// Volt calls .NET through the interop/dotnet package: hostfxr starts the runtime a C# library asks
/// for and hands out its [UnmanagedCallersOnly] methods as C functions, on both backends
#[test]
fn dotnet_package() {
    let Some(dotnet) = local_tool("dotnet", "--version") else {
        eprintln!("dotnet isn't installed: skipping the dotnet package");
        return;
    };
    let e = Env::new("dotnet");
    let app = e.dir.join("dotnet_app");
    let fx = Path::new(ROOT).join("tests/interop/dotnet_app");
    copy_dir(&fx.join("src"), &app.join("src"));
    copy_dir(&fx.join("lib"), &e.dir.join("cs"));
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"dotnet_app\"\nversion = \"0.1.0\"\n\n[dependencies]\ndotnet = {{ path = \"{}\" }}\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("interop/dotnet").display(), Path::new(ROOT).join("std").display())).unwrap();
    // the C# library, for the installed .NET
    let v = String::from_utf8_lossy(&Command::new(&dotnet).arg("--version").output().unwrap().stdout).trim().to_string();
    let framework = format!("-p:TargetFramework=net{}.0", v.split('.').next().unwrap_or("10"));
    let lib = e.dir.join("cs/bin");
    let o = Command::new(&dotnet).args(["build", "-c", "Release", "--nologo", &framework, "-o"]).arg(&lib).current_dir(e.dir.join("cs")).env("DOTNET_CLI_TELEMETRY_OPTOUT", "1").env("DOTNET_NOLOGO", "1").env("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1").output().unwrap();
    ok(o, "dotnet build");
    let want = "add 42\nmean 2.625\nhello, volt from .NET\njson {\"x\":3,\"y\":4}\napply 41\ndivide 0 3\ndivide by zero 1\nmissing true\n";
    for backend in ["c", "llvm"] {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("DOTNET_APP_LIB", &lib);
        // a .NET found through ~/.local/bin: the build file finds it through $DOTNET_ROOT
        if dotnet.parent().is_some_and(|d| !d.as_os_str().is_empty()) {
            c.env("DOTNET_ROOT", std::fs::canonicalize(&dotnet).unwrap().parent().unwrap());
        }
        let o = c.output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), want, "Volt calls .NET ({backend})");
    }
}

/// Volt uses Go: [foreign] names a Go module, bolt builds it with go build -buildmode=c-archive and
/// imports the header cgo writes, on both backends
#[test]
fn go_foreign() {
    if !Command::new("go").arg("version").output().is_ok_and(|o| o.status.success()) {
        eprintln!("go isn't installed: skipping the Go library");
        return;
    }
    let e = Env::new("go");
    let app = e.dir.join("go_app");
    copy_dir(&Path::new(ROOT).join("tests/interop/go_app"), &app);
    let toml = std::fs::read_to_string(app.join("bolt.toml")).unwrap() + &format!("\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display());
    std::fs::write(app.join("bolt.toml"), toml).unwrap();
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["run", "-q", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("GOTOOLCHAIN", "local").output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), "add 42\nsum 6.5\nupper VOLT\nwords 3\n", "Volt uses Go ({backend})");
    }
    let header = std::fs::read_to_string(app.join("target/debug/foreign/include/gomath.h")).unwrap();
    assert!(header.contains("extern int gm_add(int a, int b);"), "{header}");
}

/// Volt embeds Lua through the interop/lua package: scripts, calls, tables, a Volt function Lua
/// calls, and Lua errors as lua_error, on both backends
#[test]
fn lua_package() {
    if !Command::new("pkg-config").args(["--exists", "lua"]).status().is_ok_and(|s| s.success()) && !Command::new("pkg-config").args(["--exists", "lua5.4"]).status().is_ok_and(|s| s.success()) {
        eprintln!("Lua's development files aren't installed: skipping the lua package");
        return;
    }
    let e = Env::new("lua");
    let app = e.dir.join("lua_app");
    copy_dir(&Path::new(ROOT).join("tests/interop/lua_app/src"), &app.join("src"));
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"lua_app\"\nversion = \"0.1.0\"\n\n[dependencies]\nlua = {{ path = \"{}\" }}\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("interop/lua").display(), Path::new(ROOT).join("std").display())).unwrap();
    let want = "hi volt hi volt \nlen 3 second 9 best volt\neval 42\nmath 314\nhypot 5.0\nhypot bad hypot wants two numbers\ntype table b nil true\ncaught ERROR(run:1: boom)\nsyntax true\nERROR(a string isn't an integer)\n";
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["run", "-q", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), want, "Volt embeds Lua ({backend})");
    }
}

/// Volt calls an ordinary Rust crate directly: `use { "geom" } as geom;` and nothing else, on
/// both backends, from voltc run and from a bolt package, which rebuilds when the crate changes
#[test]
fn rust_direct() {
    let e = Env::new("rust_direct");
    let dir = e.dir.join("rd");
    copy_dir(&Path::new(ROOT).join("tests/interop/rust_direct"), &dir);
    let want = "dist 5 norm 5\nscaled 6 8\nhello, volt QUIET first\ngeom 10\nsum 7\ndoubled 2 4 6\nsquares 4 last 16\nwords 3 three\njoin a-b-c\nfind 2 true\nnickname lucky true\nor_default 5 -1\nparse 42\nbad ERROR(invalid digit found in string)\ndiv 3\nzero ERROR(1 / 0)\ncolor blue green\npixel 2 green 65\nperimeter 7 12 name tri\nside 4\nmissing ERROR(tri has no side 9)\nlongest tri\ncentroid 4.5\nconsumed 3 into tri\nproblem 3 clash 123\nsettings 4 mode Slow\nrustdoc 42 64 42 2 3\nconsts 100 0.25 true\nticks 2\n";
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("RUSTUP_TOOLCHAIN", rust_toolchain());
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // generics: each instance the program uses is made for it (fns, a method, a type), and one whose
    // types Rust's bounds reject is an error at the call, with rustc's reason
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "generics.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run generics.volt"), "largest 9 1.5\nrepeat 3 7 0.5\npick b 1\nscaled 3 6\nstack 2 5 volt 4,5\npoints 1 bigger 8\n", "generics ({backend})");
    }
    // closures and traits both ways: Volt's into Rust (lent, or kept and dropped by Rust once: drops 2, and Rust's squares 2),
    // Rust's back as values Volt calls
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "closures.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run closures.volt"), "apply 15 count 2 boxed 13\n[rust][calls][volt]\nadder 42 counter 2 initial 118\nkept 8 dropped 0\ndropped 1\n<a> <b> / hi, volt\n", "closures ({backend})");
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "traits.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run traits.volt"), "area 6 larger 6\ngrown 15\ntri of area 15 [T]\na blob of its own [B]\nrust 1 a square of side 1 circle 12\ncircle 12 C\nunion 12\ncanvas 18 tri,blob,square\ndrops 2 squares 2\n", "traits ({backend})");
    }
    // ownership and errors: every self form, references into Rust's data (lent), an error enum's
    // variants matched, panics caught (try_ forms, a closure's try_call), async fns awaited
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "ownership.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run ownership.volt"), "self 5 6 5\nrc 20 arc 300\nrefs 10 2 3 3\nvecs 3 2 2 true\nasync 2 42 9\nasync error BadDigit(121)\nparsed 42\nempty\nbad digit 120\ntoo long 5 > 4\nraw Raw([35, 49])\ntimeout\nrefused busy\nclosed\nconnected 5\npeek 7 -2 drops 0\ncounted drops 1\nonce 119\nclosure PANIC(a FnOnce closure called twice)\ncaught PANIC(index out of bounds: the len is 3 but the index is 5)\n", "ownership ({backend})");
    }
    // a panic through a plain call stops the program with Rust's message; a lent handle can't be
    // given away
    for (prog, says) in [("panic.volt", "index out of bounds: the len is 2 but the index is 3"), ("lent_move.volt", "geom::Node is lent by Rust")] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", prog]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        let o = c.output().unwrap();
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(o.status.code() == Some(101) && err.contains(says), "{prog}: {:?} {err}", o.status);
    }
    let mut c = Command::new(&e.voltc);
    c.args(["check", "traits.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std")).env("VOLT_SHOW_IMPORT", "1");
    tools(&mut c);
    let shown = String::from_utf8_lossy(&c.output().unwrap().stderr).to_string();
    assert!(shown.contains("trait Source (its associated type Item)"), "a trait Volt can't declare is left out, with why: {shown}");
    let mut c = Command::new(&e.voltc);
    c.args(["run", "generics_bad.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("dup<geom::shapes::Counter>") && err.contains("Counter: Clone"), "a rejected instance: {err}");
    // reading the crate (rustdoc documents it as the shim's dependency) writes nothing into it
    assert!(!dir.join("geom/Cargo.lock").exists() && !dir.join("geom/target").exists(), "the import wrote into the crate");
    // one .rs file is a crate of its own (its `mod x;` files next to it)
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "single.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run single.volt"), "3 n=70 20 3\n", "a single .rs file ({backend})");
    }
    // each Volt fn says what it is in Rust, above it (the editor's hover shows that comment)
    let mut c = Command::new(&e.voltc);
    c.args(["check", "single.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std")).env("VOLT_SHOW_IMPORT", "1");
    tools(&mut c);
    let o = c.output().unwrap();
    assert!(String::from_utf8_lossy(&o.stderr).contains("// Rust: pub fn mean(xs: &[f64]) -> f64\nfn mean("), "the Rust signature above its Volt fn: {}", String::from_utf8_lossy(&o.stderr));
    // a handle Rust never made stops the program, with no crash inside Rust (`use rust { }` says the
    // language outright)
    let mut c = Command::new(&e.voltc);
    c.args(["run", "empty.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an empty handle panics: {}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("geom::shapes::Shape is empty"), "{}", String::from_utf8_lossy(&o.stderr));
    // the same program in a bolt package: the path is from the file, as a header's is
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), std::fs::read_to_string(dir.join("main.volt")).unwrap().replace("use { \"geom\" }", "use { \"../../geom\" }")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    for backend in ["c", "llvm"] {
        assert_eq!(bolt_run(backend), want, "bolt run ({backend})");
    }
    // a change to the crate reaches the program: bolt rebuilds what imported it
    let lib = dir.join("geom/src/lib.rs");
    std::fs::write(&lib, std::fs::read_to_string(&lib).unwrap().replace("format!(\"hello, {who}\")", "format!(\"hi there, {who}\")")).unwrap();
    assert!(bolt_run("c").contains("hi there, volt QUIET"), "the Rust change is in");
    // the glue's library cleaned away under its cache: rebuilt, not a link error
    for d in std::fs::read_dir(e.dir.join("cache/imports")).unwrap().flatten() {
        let _ = std::fs::remove_dir_all(d.path().join("target"));
    }
    std::fs::write(app.join("src/main.volt"), std::fs::read_to_string(app.join("src/main.volt")).unwrap() + "\n").unwrap();
    assert!(bolt_run("llvm").contains("hi there, volt QUIET"), "rebuilt after its target was cleaned");
}

/// Volt calls an ordinary Zig file directly: `use { "fastmath.zig" } as fm;` and nothing else,
/// on both backends, from voltc run and from a bolt package, which rebuilds when the file changes
#[test]
fn zig_direct() {
    let Some(zig) = zig() else {
        eprintln!("zig isn't installed: skipping use zig");
        return;
    };
    let e = Env::new("zig_direct");
    let dir = e.dir.join("zd");
    copy_dir(&Path::new(ROOT).join("tests/interop/zig_direct"), &dir);
    let want = "dist 5 norm 5\nscaled 6 8\n42 fastmath 10 1.5\nfirst QUIET\nsum 7\ndoubled 2 4 6\nsquares 4 last 16\njoin a-b-c\nfind 2 true\nor_default 5 -1\nparse 42\nbad ERROR(InvalidCharacter)\ndiv 3\nzero ERROR(DivisionByZero)\ncolor blue green\npixel 2 green\ntwice 42\nperimeter 7 10 name tri\nside 4\nmissing ERROR(NoSuchSide)\nlongest quad\nconsumed 2\nticks 2 3\nlargest 9 2.5\nbigger 8 2.5 times 21 scaled 20 -10\npair 7\nstack true true false total 3 pop 2 1 true\nflags true true\n";
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("ZIG", &zig);
    };
    // (leak-checked: what Zig allocates is Volt's memory, so it's counted too)
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--leak-check", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // an instance zig rejects: zig's reason, at the call
    std::fs::write(dir.join("bad.volt"), "use std::io;\nuse { \"fastmath.zig\" } as fm;\nfn main() -> void {\n    std::println(\"{}\", fm::biggerOf(\"a\", \"b\"));\n}\n").unwrap();
    let mut c = Command::new(&e.voltc);
    c.args(["check", "bad.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("biggerOf<str>: Zig doesn't take these arguments: operator > not allowed for type '[]const u8'"), "zig's rejection: {err}");
    std::fs::remove_file(dir.join("bad.volt")).unwrap();
    // Stack(bool) is made without total, which zig rejects for it (the rest of its methods stay)
    let failed: String = std::fs::read_dir(e.dir.join("cache/imports")).unwrap().filter_map(|d| std::fs::read_to_string(d.ok()?.path().join("instances.failed")).ok()).collect();
    assert!(failed.contains("Stack\tbool\t::total\t"), "Stack(bool)'s total left out: {failed}");
    // what Zig allocates is Volt's memory: a block it never frees is a leak the check reports
    std::fs::write(dir.join("leak.volt"), "use { \"fastmath.zig\" } as fm;\nfn main() -> void {\n    fm::leakBytes(5);\n}\n").unwrap();
    let mut c = Command::new(&e.voltc);
    c.args(["run", "--leak-check", "leak.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(102), "Zig's leak is Volt's: {}", String::from_utf8_lossy(&o.stderr));
    std::fs::remove_file(dir.join("leak.volt")).unwrap();
    // each Volt fn says what it is in Zig, above it (the editor's hover shows that comment)
    let mut c = Command::new(&e.voltc);
    c.args(["check", "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std")).env("VOLT_SHOW_IMPORT", "1");
    tools(&mut c);
    let o = c.output().unwrap();
    assert!(String::from_utf8_lossy(&o.stderr).contains("// Zig: pub fn scale(self: *Point, k: f64) void\nattach fn scale("), "the Zig signature above its Volt fn: {}", String::from_utf8_lossy(&o.stderr));
    // a handle Zig never made stops the program
    let mut c = Command::new(&e.voltc);
    c.args(["run", "empty.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an empty handle panics: {}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("fm::shapes::Shape is empty"), "{}", String::from_utf8_lossy(&o.stderr));
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), std::fs::read_to_string(dir.join("main.volt")).unwrap().replace("use { \"fastmath.zig\" }", "use { \"../../fastmath.zig\" }")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    for backend in ["c", "llvm"] {
        assert_eq!(bolt_run(backend), want, "bolt run ({backend})");
    }
    // a change to an imported file reaches the program
    let f = dir.join("shapes.zig");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("self.n += 1;", "self.n += 10;")).unwrap();
    assert!(bolt_run("c").contains("ticks 20 30"), "the Zig change is in");
}

/// Volt calls ordinary Go directly: `use { "geom.go" } as geom;` (a package), `use { "shapes" }` (a
/// module's directory) and `use { "tool/tool.go" }` (a main package), and nothing else, linked with
/// one Go runtime, on both backends, from voltc run and from a bolt package, which rebuilds when the
/// Go code changes
#[test]
fn go_direct() {
    let Some(go) = local_tool("go", "version") else {
        eprintln!("go isn't installed: skipping use go");
        return;
    };
    let e = Env::new("go_direct");
    let dir = e.dir.join("gd");
    copy_dir(&Path::new(ROOT).join("tests/interop/go_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("GO", &go);
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // a handle Go never made stops the program
    let mut c = Command::new(&e.voltc);
    c.args(["run", "empty.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an empty handle panics: {}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("geom::Shape is empty"), "{}", String::from_utf8_lossy(&o.stderr));
    // a Go panic through a plain call stops the program with Go's message (recovered in the shim:
    // it never unwinds through C)
    let mut c = Command::new(&e.voltc);
    c.args(["run", "panic.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(o.status.code() == Some(101) && err.contains("index out of range [3] with length 2"), "a Go panic: {:?} {err}", o.status);
    // a Go panic while a Volt callback's slice result goes to Go is Volt's panic too (recovered in the
    // push, so it never unwinds through the callback's Volt frames)
    let mut c = Command::new(&e.voltc);
    c.args(["run", "push_panic.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(o.status.code() == Some(101) && err.contains("invalid Handle"), "a Go panic in a push: {:?} {err}", o.status);
    // an instance Go's constraint rejects is an error at the call, with go's reason
    let mut c = Command::new(&e.voltc);
    c.args(["run", "generics_bad.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("Max<bool>: Go doesn't take these types") && err.contains("does not satisfy cmp.Ordered"), "a rejected instance: {err}");
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    let in_app = src.replace("use { \"geom.go\" }", "use { \"../../geom.go\" }").replace("use { \"shapes\" }", "use { \"../../shapes\" }").replace("use { \"tool/tool.go\" }", "use { \"../../tool/tool.go\" }");
    std::fs::write(app.join("src/main.volt"), in_app).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to the Go code reaches the program: the package's, and one its module imports
    let f = dir.join("geom.go");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("strings.ToUpper(s)", "strings.ToUpper(s) + \"!\"")).unwrap();
    let f = dir.join("shapes/units/units.go");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("\" m\"", "\" metres\"")).unwrap();
    let out = bolt_run("c");
    assert!(out.contains("QUIET! a-b-c") && out.contains("6 metres²"), "the Go changes are in: {out}");
}

/// Volt calls ordinary Java directly: `use { "geo/Point.java", ... } as geo;` and nothing else (the JVM
/// starts on first use), on both backends, from voltc run and from a bolt package, which rebuilds
/// when a Java file changes
#[test]
fn java_direct() {
    let Some(bin) = jdk_bin() else {
        eprintln!("there's no JDK 22 or later: skipping use java");
        return;
    };
    let e = Env::new("java_direct");
    let dir = e.dir.join("jd");
    copy_dir(&Path::new(ROOT).join("tests/interop/java_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome"));
        // javac on the PATH is found there; else the JDK this found
        if let Some(home) = bin.parent().filter(|h| !h.as_os_str().is_empty()) {
            c.env("JAVA_HOME", home);
        }
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // an exception the method doesn't declare stops the program
    let mut c = Command::new(&e.voltc);
    c.args(["run", "panics.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an undeclared exception panics: {}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("java.lang.ArithmeticException: / by zero"), "{}", String::from_utf8_lossy(&o.stderr));
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("\"geo/", "\"../../geo/")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to a Java file reaches the program
    let f = dir.join("geo/Geom.java");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("s.toUpperCase()", "s.toUpperCase() + \"!\"")).unwrap();
    assert!(bolt_run("c").contains("42 3000000000 QUIET!"), "the Java change is in");
}

/// Volt calls ordinary C# directly: `use { "Geo.cs" } as geo;` and nothing else (.NET starts on first
/// use), on both backends, from voltc run and from a bolt package, which rebuilds when the C# changes
#[test]
fn dotnet_direct() {
    let Some(dotnet) = local_tool("dotnet", "--version") else {
        eprintln!("dotnet isn't installed: skipping use dotnet");
        return;
    };
    let e = Env::new("dotnet_direct");
    let dir = e.dir.join("nd");
    copy_dir(&Path::new(ROOT).join("tests/interop/dotnet_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("DOTNET", &dotnet);
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // an exception stops the program
    let mut c = Command::new(&e.voltc);
    c.args(["run", "panics.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an exception stops the program: {}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("System.DivideByZeroException"), "{}", String::from_utf8_lossy(&o.stderr));
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("\"Geo.cs\"", "\"../../Geo.cs\"")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to the C# reaches the program
    let f = dir.join("Geo.cs");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("s.ToUpper()", "s.ToUpper() + \"!\"")).unwrap();
    assert!(bolt_run("c").contains("QUIET! 10"), "the C# change is in");
}

/// Volt calls an ordinary Python module directly: `use { "geom.py" } as geom;` and nothing else
/// (Python starts on first use), on both backends, from voltc run and from a bolt package, which
/// rebuilds when the module changes
#[test]
fn python_direct() {
    if !Command::new("python3-config").arg("--includes").output().is_ok_and(|o| o.status.success()) {
        eprintln!("Python's development files aren't installed: skipping use python");
        return;
    }
    let e = Env::new("python_direct");
    let dir = e.dir.join("pd");
    copy_dir(&Path::new(ROOT).join("tests/interop/python_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome"));
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // an exception stops the program
    let mut c = Command::new(&e.voltc);
    c.args(["run", "panics.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an exception stops the program: {}", String::from_utf8_lossy(&o.stderr));
    // the exception's name: its message varies with Python's version ("division by zero" in 3.14,
    // "integer division or modulo by zero" before)
    assert!(String::from_utf8_lossy(&o.stderr).contains("ZeroDivisionError"), "{}", String::from_utf8_lossy(&o.stderr));
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("\"geom.py\"", "\"../../geom.py\"")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to the module reaches the program
    let f = dir.join("geom.py");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("return s.upper()", "return s.upper() + \"!\"")).unwrap();
    assert!(bolt_run("c").contains("42 2 QUIET!"), "the Python change is in");
}

/// Volt calls an ordinary TypeScript module, and JavaScript typed by a .d.ts, directly: `use {
/// "geom.ts" } as geom;` and nothing else (JavaScriptCore starts on first use), on both backends,
/// from voltc run and from a bolt package, which rebuilds when the module changes
#[test]
fn js_direct() {
    let strips = Command::new("node").args(["-e", "process.exit(typeof require('module').stripTypeScriptTypes === 'function' ? 0 : 1)"]).status().is_ok_and(|s| s.success());
    let jsc = Command::new("pkg-config").args(["--exists", "javascriptcoregtk-4.1"]).status().is_ok_and(|s| s.success());
    if !strips || !jsc {
        eprintln!("node 23.2+ or JavaScriptCore isn't installed: skipping use js");
        return;
    }
    let e = Env::new("js_direct");
    let dir = e.dir.join("jd");
    copy_dir(&Path::new(ROOT).join("tests/interop/js_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome"));
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // a thrown exception stops the program
    let mut c = Command::new(&e.voltc);
    c.args(["run", "panics.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(101), "an exception stops the program: {}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("Error: boom"), "{}", String::from_utf8_lossy(&o.stderr));
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("\"geom.ts\"", "\"../../geom.ts\"").replace("\"util.js\"", "\"../../util.js\"")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to the module reaches the program
    let f = dir.join("geom.ts");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("return s.toUpperCase();", "return s.toUpperCase() + \"!\";")).unwrap();
    assert!(bolt_run("c").contains("42 2 QUIET!"), "the TypeScript change is in");
}

/// Volt calls ordinary Kotlin (Kotlin/Native) directly: `use { "geometry.kt", "things.kt" } as geo;`
/// and nothing else, on both backends, from voltc run and from a bolt package, which rebuilds when a
/// file changes
#[test]
fn volt_calls_kotlin() {
    let Some(kotlinc) = local_tool("kotlinc-native", "-version") else {
        eprintln!("kotlinc-native isn't installed: skipping use kotlin");
        return;
    };
    let e = Env::new("kotlin_direct");
    let dir = e.dir.join("kd");
    copy_dir(&Path::new(ROOT).join("tests/interop/kotlin_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("KOTLINC_NATIVE", &kotlinc);
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("use { \"geometry.kt\", \"things.kt\" }", "use { \"../../geometry.kt\", \"../../things.kt\" }")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to a Kotlin file reaches the program
    let f = dir.join("things.kt");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("count += k", "count += 10 * k")).unwrap();
    assert!(bolt_run("c").contains("clicks 50 50"), "the Kotlin change is in");
}

/// use kotlin's cache: a second build doesn't run kotlinc-native again (the archive it made is the
/// same file), and a change to a .kt file does
#[test]
fn volt_calls_kotlin_cache() {
    let Some(kotlinc) = local_tool("kotlinc-native", "-version") else {
        eprintln!("kotlinc-native isn't installed: skipping use kotlin");
        return;
    };
    let e = Env::new("kotlin_cache");
    let dir = e.dir.join("kc");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("calc.kt"), "package calc\n\nfun twice(x: Int): Int = x * 2\n").unwrap();
    std::fs::write(dir.join("main.volt"), "use std::io;\nuse { \"calc.kt\" } as calc;\n\nfn main() -> void {\n    std::println(\"{}\", calc::twice(21));\n}\n").unwrap();
    let cache = e.dir.join("cache");
    let run = || {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        c.env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", &cache).env("KOTLINC_NATIVE", &kotlinc);
        ok(c.output().unwrap(), "voltc run")
    };
    // the archive bolt import kotlin made, and when
    let archive = || {
        let mut found = Vec::new();
        let mut todo = vec![cache.clone()];
        while let Some(d) = todo.pop() {
            for x in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = x.path();
                if p.is_dir() {
                    todo.push(p);
                } else if p.file_name().is_some_and(|n| n == "libvolt_import_calc.a") {
                    found.push((p.clone(), std::fs::metadata(&p).unwrap().modified().unwrap()));
                }
            }
        }
        assert_eq!(found.len(), 1, "one archive for the import: {found:?}");
        found.remove(0)
    };
    assert_eq!(run(), "42\n");
    let (a, made) = archive();
    assert_eq!(run(), "42\n");
    assert_eq!(archive(), (a.clone(), made), "a second run builds nothing");
    std::fs::write(dir.join("calc.kt"), "package calc\n\nfun twice(x: Int): Int = x * 2 + 1\n").unwrap();
    assert_eq!(run(), "43\n", "the change is in");
    assert_ne!(archive().1, made, "a changed file rebuilds the archive");
}

/// Volt calls ordinary Swift directly: `use { "geometry.swift", "things.swift" } as geo;` and nothing
/// else, on both backends, from voltc run and from a bolt package, which rebuilds when a file changes
#[test]
fn volt_calls_swift() {
    let Some(swiftc) = local_tool("swiftc", "--version") else {
        eprintln!("swiftc isn't installed: skipping use swift");
        return;
    };
    let e = Env::new("swift_direct");
    let dir = e.dir.join("sd");
    copy_dir(&Path::new(ROOT).join("tests/interop/swift_direct"), &dir);
    let src = std::fs::read_to_string(dir.join("main.volt")).unwrap();
    let want: String = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("SWIFTC", &swiftc);
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("use { \"geometry.swift\", \"things.swift\" }", "use { \"../../geometry.swift\", \"../../things.swift\" }")).unwrap();
    let bolt_run = |backend: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_bolt"));
        c.args(["run", "-q", "--backend", backend]).current_dir(&app);
        tools(&mut c);
        ok(c.output().unwrap(), "bolt run")
    };
    assert_eq!(bolt_run("llvm"), want, "bolt run");
    // a change to a Swift file reaches the program
    let f = dir.join("things.swift");
    std::fs::write(&f, std::fs::read_to_string(&f).unwrap().replace("count += k", "count += 10 * k")).unwrap();
    assert!(bolt_run("c").contains("clicks 50 50"), "the Swift change is in");
}

/// pip and npm build and install a Volt library themselves: interop/pip/volt_build.py as the project's
/// build backend (pip install into a venv, nothing from the network), interop/npm/volt-install.js as
/// the package's install script (npm pack, then npm install of the tarball); Python and Node call it
#[test]
fn pip_and_npm_install() {
    let e = Env::new("pip_npm");
    let pkg = e.dir.join("geo");
    std::fs::create_dir_all(pkg.join("lib")).unwrap();
    std::fs::write(pkg.join("lib/geo.volt"), "export fn area(w: f64, h: f64) -> f64 { return w * h; }\nexport fn twice(x: i32) -> i32 { return x * 2; }\n").unwrap();
    std::fs::write(pkg.join("bolt.toml"), format!("[package]\nname = \"geo\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"volt\", \"shared\"]\nbindings = [\"python\", \"pyi\", \"node\", \"js\", \"ts\"]\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display())).unwrap();
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("BOLT_HOME", e.dir.join("bolthome")).env("npm_config_cache", e.dir.join("npm-cache"));
    };
    let elsewhere = e.dir.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();

    // pip: the backend file in the project, named by pyproject.toml
    std::fs::copy(Path::new(ROOT).join("interop/pip/volt_build.py"), pkg.join("volt_build.py")).unwrap();
    std::fs::write(pkg.join("pyproject.toml"), "[build-system]\nrequires = []\nbuild-backend = \"volt_build\"\nbackend-path = [\".\"]\n\n[project]\nname = \"volt-geo\"\nversion = \"0.1.0\"\n").unwrap();
    let venv = e.dir.join("venv");
    if Command::new("python3").args(["-m", "venv"]).arg(&venv).output().is_ok_and(|o| o.status.success()) {
        let mut c = Command::new(venv.join("bin/pip"));
        c.args(["install", "--no-index", "--disable-pip-version-check", "-q"]).arg(&pkg);
        tools(&mut c);
        ok(c.output().unwrap(), "pip install");
        let o = Command::new(venv.join("bin/python")).args(["-c", "import geo; print(geo.area(2.0, 3.5), geo.twice(21))"]).current_dir(&elsewhere).output().unwrap();
        assert_eq!(ok(o, "python (pip installed)"), "7.0 42\n", "Python calls the package pip installed");
        // from its sdist too, built somewhere else
        let o = Command::new(venv.join("bin/python")).args(["-c", "import sys, volt_build; print(volt_build.build_sdist(sys.argv[1]))"]).arg(&e.dir).current_dir(&pkg).output().unwrap();
        let sdist = e.dir.join(ok(o, "build_sdist").trim());
        let mut c = Command::new(venv.join("bin/pip"));
        c.args(["install", "--no-index", "--disable-pip-version-check", "-q", "--force-reinstall"]).arg(&sdist);
        tools(&mut c);
        ok(c.output().unwrap(), "pip install (sdist)");
        let o = Command::new(venv.join("bin/python")).args(["-c", "import geo; print(geo.twice(4))"]).current_dir(&elsewhere).output().unwrap();
        assert_eq!(ok(o, "python (pip installed from the sdist)"), "8\n");
    } else {
        eprintln!("python3 -m venv doesn't work: skipping pip install");
    }

    // npm: the install script in the package, run when the tarball is installed
    if node_include().is_none() {
        eprintln!("node or its headers aren't installed: skipping npm install");
        return;
    }
    std::fs::copy(Path::new(ROOT).join("interop/npm/volt-install.js"), pkg.join("volt-install.js")).unwrap();
    std::fs::write(pkg.join("package.json"), "{\n  \"name\": \"volt-geo\",\n  \"version\": \"0.1.0\",\n  \"main\": \"target/release/bindings/geo.js\",\n  \"types\": \"target/release/bindings/geo.d.ts\",\n  \"files\": [\"bolt.toml\", \"lib\", \"volt-install.js\"],\n  \"scripts\": { \"install\": \"node volt-install.js\" }\n}\n").unwrap();
    let mut c = Command::new("npm");
    c.args(["pack", "--silent", "--pack-destination"]).arg(&e.dir).current_dir(&pkg);
    tools(&mut c);
    ok(c.output().unwrap(), "npm pack");
    // the consumer: its own package.json (else npm installs into a project further up), which lets
    // volt-geo's install script run (npm skips a dependency's unless allowScripts names it: by name
    // from a registry, by its file: path from a tarball, as `npm install-scripts approve` writes it)
    let tgz = e.dir.join("volt-geo-0.1.0.tgz");
    std::fs::write(elsewhere.join("package.json"), format!("{{\n  \"name\": \"consumer\",\n  \"private\": true,\n  \"allowScripts\": {{ \"file:{}\": true }}\n}}\n", tgz.display())).unwrap();
    let mut c = Command::new("npm");
    c.args(["install", "--offline", "--no-audit", "--no-fund", "--silent"]).arg(&tgz).current_dir(&elsewhere);
    tools(&mut c);
    ok(c.output().unwrap(), "npm install");
    let o = Command::new("node").args(["-e", "const g = require('volt-geo'); console.log(g.area(2, 3.5), g.twice(21))"]).current_dir(&elsewhere).output().unwrap();
    assert_eq!(ok(o, "node (npm installed)"), "7 42\n", "Node calls the package npm installed");
}

/// a Node.js addon written in Volt with interop/node: bolt builds it as a shared library, node
/// loads it (as a .node file), on both backends
#[test]
fn node_addon() {
    if node_include().is_none() {
        eprintln!("node or its headers aren't installed: skipping the Volt addon");
        return;
    }
    let e = Env::new("node_addon");
    let pkg = e.dir.join("addon");
    copy_dir(&Path::new(ROOT).join("tests/interop/node_addon/lib"), &pkg.join("lib"));
    std::fs::write(pkg.join("bolt.toml"), format!("[package]\nname = \"addon\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"shared\"]\n\n[dependencies]\nnode = {{ path = \"{}\" }}\n\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("interop/node").display(), Path::new(ROOT).join("std").display())).unwrap();
    let want = "add 5.5\nhello, volt hello, 42\nsum 6.5\npoint {\"x\":3,\"y\":4,\"label\":\"point\",\"pair\":[3,4]}\napply 42 from volt\nthrown true volt says no\ncaught THROWN(js says no)\nkinds number string boolean null undefined object object function\n";
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["build", "-q", "--backend", backend]).current_dir(&pkg).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).output().unwrap();
        assert!(o.status.success(), "bolt build ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        let node_file = e.dir.join(format!("addon-{backend}.node"));
        std::fs::copy(pkg.join("target/debug/libaddon.so"), &node_file).unwrap();
        let o = Command::new("node").arg(Path::new(ROOT).join("tests/interop/node_addon/test.js")).arg(&node_file).output().unwrap();
        assert_eq!(ok(o, "node test.js"), want, "a Volt addon ({backend})");
    }
}

/// a Swift, Kotlin or .NET import shows each fn's own declaration above its Volt fn (the hover's text),
/// as Rust, Zig and Go do
#[test]
fn import_decl_comments() {
    for (tool, arg, env, fixture, want) in [
        ("swiftc", "--version", "SWIFTC", "swift_direct", "// Swift: func scaled(by k: Double) -> Point\n"),
        ("kotlinc-native", "-version", "KOTLINC_NATIVE", "kotlin_direct", "// Kotlin: fun scaled(k: Double): Point\n"),
        ("dotnet", "--version", "DOTNET", "dotnet_direct", "// .NET: public double Norm()\n"),
    ] {
        let Some(path) = local_tool(tool, arg) else {
            eprintln!("{tool} isn't installed: skipping its declaration comments");
            continue;
        };
        let e = Env::new(&format!("decl_{fixture}"));
        let dir = e.dir.join("d");
        copy_dir(&Path::new(ROOT).join("tests/interop").join(fixture), &dir);
        let mut c = Command::new(&e.voltc);
        c.args(["check", "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std")).env("VOLT_SHOW_IMPORT", "1");
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env(env, &path);
        let o = c.output().unwrap();
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(err.contains(want), "{fixture}: the declaration above its Volt fn: {err}");
    }
}

/// copies directory from into to (made if needed)
fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap().flatten() {
        let (src, dst) = (e.path(), to.join(e.file_name()));
        if src.is_dir() {
            copy_dir(&src, &dst);
        } else {
            std::fs::copy(&src, &dst).unwrap();
        }
    }
}

/// the toolchain a Cargo build outside this repository uses (its rust-toolchain.toml doesn't reach
/// there): the one running these tests
fn rust_toolchain() -> String {
    std::env::var("RUSTUP_TOOLCHAIN").unwrap_or_else(|_| "stable".into())
}

/// Volt and the systems languages, both ways: a bolt package uses a Rust crate and a Zig file
/// ([foreign]: bolt builds them and writes their C headers), a Cargo project uses a Volt package
/// (interop/rust/volt-build) and so does a Zig one (interop/zig/volt.zig)
#[test]
fn foreign_libraries() {
    let e = Env::new("foreign");
    let Some(zig) = zig() else {
        eprintln!("zig isn't installed: skipping the Rust and Zig round trips");
        return;
    };
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let fx = Path::new(ROOT).join("tests/interop/foreign");
    copy_dir(&fx.join("rs_geom"), &e.dir.join("rs_geom"));
    copy_dir(&fx.join("app"), &e.dir.join("app"));
    let app = e.dir.join("app");
    let toml = std::fs::read_to_string(app.join("bolt.toml")).unwrap() + &format!("\n[std]\npath = \"{}\"\n", Path::new(ROOT).join("std").display());
    std::fs::write(app.join("bolt.toml"), toml).unwrap();
    let want = "dist 5 quadrant 4\nscaled 6 -8\nchars 5 apply 42\nclamp 10 0\nsum 10\nwidened -5 15\n";
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["run", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("ZIG", &zig).env("CARGO", &cargo).env("RUSTUP_TOOLCHAIN", rust_toolchain()).output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), want, "Volt uses Rust and Zig ({backend})");
    }
    let header = std::fs::read_to_string(app.join("target/debug/foreign/include/rs_geom.h")).unwrap();
    assert!(header.contains("double rg_dist(Point a, Point b);") && !header.contains("not_for_c"), "{header}");

    // Rust uses Volt: a build script with volt-build, the bindings included as module mathlib
    let rs = e.dir.join("rsapp");
    std::fs::create_dir_all(rs.join("src")).unwrap();
    std::fs::write(rs.join("Cargo.toml"), format!("[package]\nname = \"rsapp\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[build-dependencies]\nvolt-build = {{ path = \"{}\" }}\n", Path::new(ROOT).join("interop/rust/volt-build").display())).unwrap();
    std::fs::write(rs.join("build.rs"), format!("fn main() {{\n    volt_build::Package::new(\"mathlib\", \"{}\").build();\n}}\n", Path::new(ROOT).join("tests/interop/mathlib/lib").display())).unwrap();
    std::fs::write(rs.join("src/main.rs"), "include!(concat!(env!(\"OUT_DIR\"), \"/mathlib.rs\"));\nuse mathlib::*;\n\nfn main() {\n    println!(\"add {}\", ml_add(2, 3));\n    println!(\"greet {}\", ml_greet(\"volt\"));\n    println!(\"sqrt {}\", ml_sqrt(-1.0).is_err());\n}\n").unwrap();
    let o = Command::new(&cargo).args(["run", "-q", "--offline"]).current_dir(&rs).env("VOLTC", &e.voltc).env("VOLT_STD", Path::new(ROOT).join("std")).env("CARGO_TARGET_DIR", rs.join("target")).env("RUSTUP_TOOLCHAIN", rust_toolchain()).output().unwrap();
    assert_eq!(ok(o, "cargo run (volt-build)"), "add 5\ngreet hello, volt\nsqrt true\n", "Rust uses Volt");

    // Zig uses Volt: build.zig adds the package with volt.zig
    let zd = e.dir.join("zigapp");
    std::fs::create_dir_all(zd.join("src")).unwrap();
    std::fs::copy(Path::new(ROOT).join("interop/zig/volt.zig"), zd.join("volt.zig")).unwrap();
    std::fs::write(zd.join("build.zig"), format!("const std = @import(\"std\");\nconst volt = @import(\"volt.zig\");\n\npub fn build(b: *std.Build) void {{\n    const exe = b.addExecutable(.{{\n        .name = \"zigapp\",\n        .root_module = b.createModule(.{{\n            .root_source_file = b.path(\"src/main.zig\"),\n            .target = b.standardTargetOptions(.{{}}),\n            .optimize = b.standardOptimizeOption(.{{}}),\n        }}),\n    }});\n    volt.addPackage(b, exe, \"mathlib\", \"{}\");\n    const run = b.addRunArtifact(exe);\n    b.step(\"run\", \"run it\").dependOn(&run.step);\n}}\n", Path::new(ROOT).join("tests/interop/mathlib/lib").display())).unwrap();
    std::fs::write(zd.join("src/main.zig"), "const std = @import(\"std\");\nconst mathlib = @import(\"mathlib\");\n\npub fn main() void {\n    std::debug.print(\"add {d}\\n\", .{mathlib.ml_add(2, 3)});\n}\n".replace("std::debug", "std.debug")).unwrap();
    // on Linux, Zig's own glibc start files (newer system ones can have sections its linker doesn't read)
    let mut z = Command::new(&zig);
    z.args(["build", "run"]).current_dir(&zd).env("VOLTC", &e.voltc).env("VOLT_STD", Path::new(ROOT).join("std"));
    if cfg!(target_os = "linux") {
        z.arg(format!("-Dtarget={}-linux-gnu", std::env::consts::ARCH));
    }
    let o = z.output().unwrap();
    assert!(o.status.success(), "zig build run: {}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(String::from_utf8_lossy(&o.stderr), "add 5\n", "Zig uses Volt");
}

#[test]
fn cpp_derive() {
    // Volt types subclassing C++ classes: C++ calls their overrides through base references, the
    // override reaches the base implementation and protected members, the Volt value goes with the
    // C++ object; and none of it needs RTTI
    let e = Env::new("cpp-derive");
    let want = "[ok 5 boxy] clicks 202 shown true\n[lbl 5] 10 true\n[x 5 boxy] area 10 poke 41 id 7\nmine 5 log:xlbl true\npress 11 [knob] ring 60\nboxy 5 gone\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive.volt", "--backend", backend]), "voltc run cpp_derive.volt"), want, "C++ derive ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_derive.volt"], Some("c++ -fno-rtti")), "voltc run cpp_derive.volt (-fno-rtti)"), want, "C++ derive without RTTI");
    // a pure virtual method the Volt type doesn't override is a compile error naming it
    let hpp = Path::new(ROOT).join("tests/interop/widgets.hpp");
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct nothing {{ n: i32; }}\nfn main() -> void {{\n    val x: nothing = {{ n: 1 }};\n    val w = cpp::gui::Widget::derive(move x, \"a\");\n}}\n", hpp.display());
    std::fs::write(e.dir.join("cpp_derive_pure.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_derive_pure.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("has to override width, which is pure virtual"), "pure virtual: {err}");
    // so is one the class doesn't have, in the attach block
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct nothing {{ n: i32; }}\nattach cpp::gui::Widget -> nothing {{\n    fn width(this, self: cpp::gui::Widget&) -> i32 {{ return 1; }}\n    fn widht(this, self: cpp::gui::Widget&) -> i32 {{ return 2; }}\n}}\nfn main() -> void {{}}\n", hpp.display());
    std::fs::write(e.dir.join("cpp_derive_extra.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_derive_extra.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("'widht' isn't one of Widget's functions"), "not a virtual method: {err}");
    // and one whose self is another class (it would override nothing)
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct nothing {{ n: i32; }}\nattach cpp::gui::Button -> nothing {{\n    fn sound(this, self: cpp::gui::Button&) -> i32 {{ return 1; }}\n    fn press(this, self: cpp::gui::Widget&) -> i32 {{ return 2; }}\n}}\nfn main() -> void {{}}\n", hpp.display());
    std::fs::write(e.dir.join("cpp_derive_self.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_derive_self.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("'press' takes a cpp::gui::Widget& as argument 1 here but a cpp::gui::Button& in 'Button'"), "another self: {err}");
}

#[test]
fn cpp_derive_any() {
    // a Volt subclass overriding methods that take a std::map, a class held by handle, a
    // std::function, a std::vector to fill and a T&&, and give back a std::map; a std::map ordered
    // by std::greater isn't stdcxx::map<i32, i32>; copying the derived object copies the Volt side;
    // a derived Mid seen through as_Base(); a derived object C++ hands back is still known
    // (derived<T>(), cpp_type_name(), deleted as what it is: the base's destructor isn't virtual),
    // with or without RTTI
    let e = Env::new("cpp-derive-any");
    let want = "31 10 701 140 4\ncopy 1031 1001\nsummer 1001 gone\n7 summer\nsink 109 top 5\nmid -1 plain true\nsame 1 summer\npassed 1031 summer\nsummer 1001 gone\nsummer 1 gone\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive2.volt", "--backend", backend]), "voltc run cpp_derive2.volt"), want, "C++ derive, any types ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_derive2.volt"], Some("c++ -fno-rtti")), "voltc run cpp_derive2.volt (-fno-rtti)"), want, "C++ derive, any types, without RTTI");
}

#[test]
fn cpp_module() {
    // a C++20 named module (its interface imports std) and a header doing `import std;`: read by
    // libclang from clang-precompiled modules, built by $CXX its own way (g++'s module mapper,
    // clang's -fmodule-file); what the module doesn't export isn't there
    let e = Env::new("cpp-module");
    let want = "42 n=7 12 6\n6 hi volt 8\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_module.volt", "--backend", backend]), "voltc run cpp_module.volt"), want, "C++ modules ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_module.volt"], Some("clang++")), "voltc run cpp_module.volt (clang++)"), want, "C++ modules built by clang++");
    let src = format!("use {{ \"{}\" }} as gm;\nfn main() -> void {{\n    val x = gm::hidden_helper(1);\n}}\n", Path::new(ROOT).join("tests/interop/geomod.cppm").display());
    std::fs::write(e.dir.join("cpp_module_hidden.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_module_hidden.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("unknown name 'hidden_helper'"), "an unexported name: {err}");
}

#[test]
fn cpp_rtti() {
    // casts between classes (multiple inheritance, a base held by value), dynamic types, and a
    // cpp_error variant each exception: the standard ones and the library's own
    let e = Env::new("cpp-rtti");
    let want = "woof named zoo::Dog\n3 true\nmeow true zoo::Cat\nanimal! animal\nzoo::Animal\nwoof 3\n6 box\n5 fed 10\n-1 INVALID_ARGUMENT: negative food\n500 OUT_OF_RANGE: too much food\n7 escaped: the tiger escaped\n8 zoo_error: closed\n9 UNKNOWN: an exception that isn't a std::exception\n10 BAD_ALLOC: std::bad_alloc\n11 EXCEPTION: std::bad_exception\n12 UNKNOWN: an exception that isn't a std::exception\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_rtti.volt", "--backend", backend]), "voltc run cpp_rtti.volt"), want, "C++ RTTI ({backend})");
    }
    // built without RTTI, it compiles, and what needs RTTI stops the program saying so
    let o = e.voltc_cxx(&["run", "cpp_rtti.volt"], Some("c++ -fno-rtti"));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("needs RTTI, and the C++ was built without it"), "-fno-rtti: {err}");
}

#[test]
fn cpp_surface() {
    // constants, static members, nested classes, conversion and assignment operators, T&& results,
    // member templates, and std::function both ways (a Volt closure in, a C++ callable out)
    let e = Env::new("cpp-surface");
    let want = "42 1.5 true kit \"tools\" 1\n10 true 3\n12 1.5 12\ncreated 4\nreg k 42\nstolen 9\n41\n1.5\ntrue\n6 42\ntrue 1 1\n15 8\n7 5\n7 6 48\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_surface.volt", "--backend", backend]), "voltc run cpp_surface.volt"), want, "C++ surface ({backend})");
    }
    // {&i} takes a function
    let hpp = Path::new(ROOT).join("tests/interop/surface.hpp");
    let src = format!("use {{ \"{}\" }} as cpp;\nfn main() -> void {{\n    val x = @cpp<i32>(\"kit::apply_fn<{{&0}}, true>(1)\", 5);\n}}\n", hpp.display());
    std::fs::write(e.dir.join("cpp_hole.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_hole.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("{&0} is a function's symbol: pass a function"), "{{&0}} of a number: {err}");
}

#[test]
fn cpp_templates() {
    // what Volt's generics can't declare (variadic and non-type templates, auto results, constrained
    // templates, function-like macros, method templates), called per use: clang types each call
    let e = Env::new("cpp-templates");
    let want = "6.5 4\n12\n42 2.5\n3 6\n40\n25 2\n6 18\n6\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_templates.volt", "--backend", backend]), "voltc run cpp_templates.volt"), want, "C++ templates ({backend})");
    }
    // a call C++ rejects is an error at the Volt call, in C++'s words: here the concept
    let hpp = Path::new(ROOT).join("tests/interop/templates.hpp");
    let src = format!("use {{ \"{}\" }} as cpp;\nfn main() -> void {{\n    val x = cpp::tpl::twice(1.5);\n}}\n", hpp.display());
    std::fs::write(e.dir.join("cpp_concept.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_concept.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("cpp_concept.volt:3") && err.contains("constraints not satisfied"), "a call the concept rejects: {err}");
}

#[test]
fn cpp_versions() {
    // headers for C++98 (what C++17 removed: auto_ptr, throw(), register), 11, 17, 20 and 23 in one
    // program, each read and compiled under its own standard
    let e = Env::new("cpp-versions");
    let want = "5 42\n0 v98::Shape\n49 3 2\n4 1 107\n4 11\n5 15 5\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_versions.volt", "--backend", backend]), "voltc run cpp_versions.volt"), want, "C++ versions ({backend})");
    }
    // one standard for the whole program (--cc -std=...); with none, the newest the compilers take,
    // where C++17's removals are errors
    assert_eq!(ok(e.voltc(&["run", "cpp_std_flag.volt", "--cc", "-std=c++14"]), "voltc run --cc -std=c++14"), "42 201402\n");
    let o = e.voltc(&["run", "cpp_std_flag.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("dynamic exception specifications"), "the newest standard by default: {err}");
    assert_eq!(ok(e.voltc(&["run", "cpp_old_only.volt"]), "voltc run cpp_old_only.volt"), "42\n");
}

#[test]
fn c_versions_flag() {
    // one C standard for the whole program: gnu17, so the C23 header (@standard("c23")) is kept out
    // of Volt's C, in a unit of its own, as the C89 and C99 ones are
    let e = Env::new("c-versions-flag");
    let want = "5 1 3.5 1.5\n32 true 7\n6\n10 42 true true\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "../run/c_versions.volt", "--cc", "-std=gnu17", "--backend", backend]), "voltc run c_versions.volt --cc -std=gnu17"), want, "C versions under gnu17 ({backend})");
    }
}

#[test]
fn cpp_opaque() {
    // C++ types Volt can't lay out, by value: a class template with private state and a base (and
    // the alias naming its instance), one with virtual methods, a lambda's type, a coroutine-style
    // task; their methods worked out per use
    let e = Env::new("cpp-opaque");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_opaque.volt", "--backend", backend]), "voltc run cpp_opaque.volt"), "2 1 -1\n5 1\n7 9\n15\n42 true\n-4 7 true\n2\n", "opaque C++ types ({backend})");
    }
    let o = e.voltc(&["check", "cpp_opaque_no_default.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("C++'s op::box<int32_t> can't be made from nothing") && err.contains("cpp_opaque_no_default.volt:5"), "{{}} of an instance with no default constructor: {err}");
}

#[test]
fn cpp_stdlib() {
    // the C++ standard library: class templates by the headers' names (held by handle, members per
    // use, for over each), and optional, pair, tuple, array, span, string_view, variant and a view
    // in a header's signatures as Volt's own forms
    let e = Env::new("cpp-stdlib");
    let want = "1:10 2:20 | 2 20\n1.5 1 true 4 1 2 3\n4 true 4 -1\n3 0.75 | 12 true 1.5\n2.5 9 25\n6 15 42\ntwo 4\nint 7\ndouble 2.5\nsquares 30\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_stdlib.volt", "--backend", backend]), "voltc run cpp_stdlib.volt"), want, "the C++ standard library ({backend})");
    }
}

#[test]
fn cpp_refs() {
    // T*, T&, const T& of an uncopyable class, unique_ptr and shared_ptr over handle classes, a
    // class whose copy doesn't compile, a diamond's bases by path
    let e = Env::new("cpp-refs");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_refs.volt", "--backend", backend]), "voltc run cpp_refs.volt"), "find 2 true\nfirst 101 last 2\nid_of 2 -1\ntake 2 1\nput 2\nowned 2\nshare 7\ndiamond 1 1\n", "reference shapes ({backend})");
    }
    let o = e.voltc(&["check", "cpp_refs_no_copy.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("can't copy cpp::rf::Shelf") && err.contains("cpp_refs_no_copy.volt:7"), "a class whose copy doesn't compile has no copy: {err}");
}

#[test]
fn cpp_errors() {
    // try_ forms whatever the result (a handle, a reference, an optional, a vector), and an
    // exception from C++ Volt called in a callback reaching the C++ that called the callback
    let e = Env::new("cpp-errors");
    let want = "make 2: 2\nmake -2: INVALID_ARGUMENT negative box\nat 0: 1\nat 3: OUT_OF_RANGE no box 3\nparse '42': 42\nparse 'x': -1\nparse '': bad_input empty\nrange 3: 3\nrange -1: LENGTH_ERROR negative range\nok 20\ncaught bad_input: too big\nok -1\nwalked 6\nwalk caught bad_input: too big\nlimit 4: 4\nlimit 12: OUT_OF_RANGE\nnew -5: INVALID_ARGUMENT\npair -1: DOMAIN_ERROR\npair 1: 1 0.5\nas 5: 2.5\nas -5: bad_input\nslot 0: 7\nslot 1: OUT_OF_RANGE\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_errors.volt", "--backend", backend]), "voltc run cpp_errors.volt"), want, "C++ exceptions ({backend})");
    }
}

#[test]
fn cpp_fields() {
    // bit-fields, a std::function field keeping the closure Volt set, namespace variables C++ may
    // change, constants clang can't work out
    let e = Env::new("cpp-fields");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_fields.volt", "--backend", backend]), "voltc run cpp_fields.volt"), "flags 1 5 9\ndevice 1 true\nscaled 21\ntally 3 gone\nscaled 8\ncounter 11 11\nbanner bye\nmain 1\n42 bits and bytes\n", "C++ fields and values ({backend})");
    }
    let o = e.voltc(&["check", "cpp_fields_borrow.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("can't capture by reference") && err.contains("cpp_fields_borrow.volt:7"), "a closure capturing by reference can't be kept: {err}");
}

#[test]
fn cpp_handles_are_never_empty() {
    // {} default-constructs a class held by handle, in a variable or a struct's field; one with no
    // default constructor makes {} an error at the literal
    let e = Env::new("cpp-handle-default");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_handle_default.volt", "--backend", backend]), "voltc run cpp_handle_default.volt"), "anon anon 2 given\n", "{{}} handles ({backend})");
    }
    let o = e.voltc(&["check", "cpp_handle_no_default.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("C++'s h::only can't be made from nothing") && err.contains("cpp_handle_no_default.volt:5"), "{{}} of a class with no default constructor: {err}");
}

/// is a C++ library's header on the usual include paths?
fn installed(header: &str) -> bool {
    ["/usr/include", "/usr/local/include", "/opt/homebrew/include"].iter().any(|d| Path::new(d).join(header).is_file())
}

#[test]
fn cpp_libs() {
    // libraries as installed, imported from the include path: their own declarations come through
    // (not the system's), every generated wrapper compiles, and what maps runs; one that isn't
    // installed is skipped
    let e = Env::new("cpp-libs");
    let libs = [
        ("re2/re2.h", "libs/re2.volt", &["--cc", "-lre2"][..], "true a(b+)c 1\nfalse\n"),
        ("nlohmann/json.hpp", "libs/json.volt", &[][..], "true 3\ntrue 2 {\"a\":3,\"b\":[1,2]}\n"),
        ("glm/glm.hpp", "libs/glm.volt", &[][..], "2.5 3 1\n"),
    ];
    for (header, file, flags, want) in libs {
        if !installed(header) {
            eprintln!("skipped {file}: {header} isn't installed");
            continue;
        }
        for backend in ["c", "llvm"] {
            let mut args = vec!["run", file, "--backend", backend];
            args.extend_from_slice(flags);
            assert_eq!(ok(e.voltc(&args), file), want, "{file} ({backend})");
        }
    }
}

#[test]
fn cpp_framework() {
    // Volt types as a C++ framework's listeners and plugins, called through its base classes
    let e = Env::new("cpp-framework");
    let want = "2 2\n2 5 2 50\ncount+broken- count-broken-\ntrue\n3 both/plugin 1\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_framework.volt", "--backend", backend]), "voltc run cpp_framework.volt"), want, "C++ framework ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_framework.volt"], Some("c++ -fno-rtti")), "voltc run cpp_framework.volt (-fno-rtti)"), want, "C++ framework without RTTI");
}

#[test]
fn cpp_import() {
    let e = Env::new("cpp");
    let want = "make 2 3\narea 6\nfields 5 6\nscaled 60 15\ncount 7 name rect\nmake 4 4\nkind 4 1\ntotal 46\ncopy 4 4\ncopied 16\ndrop 4 4\ndrop 4 4\ndrop 5 6\nadd 3 3.5\nbiggest 9 2.5\nbox 6\nenum 4 1\nsize 16 16\nrings 20 true\nnamed short#5 5 5 6\ncopy keeps 5 9\nshelf 8 record 7 20 1/2 registry 3\n";
    let want_std = "hello, volt 3\nfirst lorem\nsum 6.5\nrange 4 9\nvec 4 -6 6\neq true 10\nnode 4\ntaken 40\nshared 7 2\nbuffer abcd 4\nparse 42\nbad -1 trailing characters in '4x'\nerror OUT_OF_RANGE not positive\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_import.volt", "--backend", backend, "--cc", "-D", "--cc", "SHAPES_FLAG"]), "voltc run cpp_import.volt"), want, "C++ import ({backend})");
        // an exception stops the program with its message
        let o = e.voltc(&["run", "cpp_throws.volt", "--backend", backend, "--cc", "-DSHAPES_FLAG"]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(o.status.code() == Some(101) && err.contains("C++ exception") && err.contains("negative"), "C++ exception ({backend}): {err}");
        // the standard library in signatures (strings, vectors, smart pointers), operators, T&&, and
        // exceptions caught by try_ forms
        assert_eq!(ok(e.voltc(&["run", "cpp_std.volt", "--backend", backend]), "voltc run cpp_std.volt"), want_std, "C++ std types ({backend})");
    }
}

/// examples/interop: each example's run.sh prints its expected.txt, run from a copy of the directory
/// with the voltc and bolt under test (a script exits 77 when its toolchain isn't installed)
#[test]
fn interop_examples() {
    let e = Env::new("examples");
    let dir = e.dir.join("interop");
    copy_dir(&Path::new(ROOT).join("examples/interop"), &dir);
    let _ = std::fs::remove_dir_all(dir.join("calls-volt/greet/target"));
    let path = std::env::var("PATH").unwrap_or_default();
    let path = std::env::var("HOME").map(|h| format!("{h}/.local/bin:{path}")).unwrap_or(path);
    let (mut ran, mut skipped) = (Vec::new(), Vec::new());
    for side in ["calls-volt", "volt-calls"] {
        let mut examples: Vec<PathBuf> = std::fs::read_dir(dir.join(side)).unwrap().flatten().map(|d| d.path()).filter(|p| p.join("run.sh").is_file()).collect();
        examples.sort();
        for ex in examples {
            let name = format!("{side}/{}", ex.file_name().unwrap().to_string_lossy());
            let mut c = Command::new("sh");
            c.arg(ex.join("run.sh")).env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_STD", Path::new(ROOT).join("std"));
            c.env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("PATH", &path).env("RUSTUP_TOOLCHAIN", rust_toolchain());
            if let Some(z) = zig() {
                c.env("ZIG", z);
            }
            if let Some(home) = jdk_bin().and_then(|b| b.parent().map(Path::to_path_buf)) {
                c.env("JAVA_HOME", home);
            }
            for (var, tool, arg) in [("DOTNET", "dotnet", "--version"), ("DART", "dart", "--version"), ("SWIFTC", "swiftc", "--version"), ("KOTLINC_NATIVE", "kotlinc-native", "-version")] {
                if let Some(t) = local_tool(tool, arg) {
                    c.env(var, t);
                }
            }
            let o = c.output().unwrap();
            if o.status.code() == Some(77) {
                skipped.push(name);
                continue;
            }
            assert!(o.status.success(), "{name}: run.sh failed:\n{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
            let want = std::fs::read_to_string(ex.join("expected.txt")).unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stdout), want, "{name} prints something else");
            ran.push(name);
        }
    }
    eprintln!("interop examples: ran {ran:?}; skipped (no toolchain) {skipped:?}");
    assert!(ran.iter().any(|n| n == "calls-volt/c") && ran.iter().any(|n| n == "volt-calls/c"), "the C examples always run");
}

/// A package's library (voltc lib) that calls a C shared library links when the linker drops
/// libraries nothing has asked for yet (--as-needed, Ubuntu's gcc default): both compilers put
/// --cc's -l libraries after the archives that use them (stage 0 too: it links stage 1 against LLVM
/// with --cc -lLLVM)
#[test]
fn libraries_link_after_archives() {
    let e = Env::new("linkorder");
    let d = &e.dir;
    std::fs::write(d.join("answer.c"), "int c_answer(void) { return 42; }\n").unwrap();
    ok(Command::new("cc").args(["-shared", "-fPIC", "-o"]).arg(d.join("libanswer.so")).arg(d.join("answer.c")).output().unwrap(), "cc -shared");
    std::fs::create_dir_all(d.join("ans")).unwrap();
    std::fs::write(d.join("ans/ans.volt"), "extern \"C\" fn c_answer() -> i32;\npublic fn answer() -> i32 { return c_answer(); }\n").unwrap();
    std::fs::write(d.join("main.volt"), "use std::io;\nfn main() -> void { std::println(ans::answer()); }\n").unwrap();
    let std_dir = Path::new(ROOT).join("std");
    for (name, compiler) in [("bootstrap", PathBuf::from(env!("CARGO_BIN_EXE_voltc-bootstrap"))), ("voltc", e.voltc.clone())] {
        let lib = d.join(format!("libans-{name}.a"));
        let pkg = format!("ans={}", d.join("ans").display());
        ok(Command::new(&compiler).args(["lib", "ans", "--pkg", &pkg, "-o"]).arg(&lib).arg("--std").arg(&std_dir).output().unwrap(), &format!("{name} lib"));
        let exe = d.join(format!("prog-{name}"));
        // voltc through its C backend, the one CI's dotnet test links with (the bootstrap is C only)
        let backend: &[&str] = if name == "voltc" { &["--backend", "c"] } else { &[] };
        let o = Command::new(&compiler)
            .arg("build")
            .arg(d.join("main.volt"))
            .args(["--pkg", &pkg, "--link"])
            .arg(format!("ans={}", lib.display()))
            .args(backend)
            .args(["--cc", "-Wl,--as-needed", "--cc"])
            .arg(format!("-L{}", d.display()))
            .args(["--cc", "-lanswer", "--cc"])
            .arg(format!("-Wl,-rpath,{}", d.display()))
            .arg("--std")
            .arg(&std_dir)
            .arg("-o")
            .arg(&exe)
            .output()
            .unwrap();
        ok(o, &format!("{name} build with --as-needed"));
        assert_eq!(ok(Command::new(&exe).output().unwrap(), &format!("{name}'s program")), "42\n");
    }
}
