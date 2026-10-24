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
const MATHLIB_OUT: &str = "add 5\ndot 11\nscale 2 4\nlen 5\nclash 895\ntags 1 2 3 4 34\nbump 8 5\nnext 2\nsqrt 3 1\nerror negative\ngreet hello, volt\nrepeat abab\nrepeat negative\nsum 6.5\nfind 2 none\neach 4 5 6 = 15\ncounter clicks 5\ntake negative\nlabel 15\nlabel_of ab 3 6 9 1.5\nlabels 36\nholder 3\nor 4.5 9.5\nask 18\nrelabel ab 7 6 9\ncount 40\nnote 7\nor_label 15 -1\ngiven 66 9.5\ndeep 10 4 8 words 6\ntext_given 10 17\nturn 321\nturner 321 flipped 654\npair 6 ab cd shelf 18 back 2 abc\nvector 6 8 10 12 36\n";

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

/// stdout of a command that must succeed (a C program's text-mode stdout on Windows ends lines
/// in \r\n: read as \n)
fn ok(o: Output, what: &str) -> String {
    let out = String::from_utf8_lossy(&o.stdout).replace("\r\n", "\n");
    assert!(o.status.success(), "{what} failed ({})\n--- stdout\n{out}\n--- stderr\n{}", o.status, String::from_utf8_lossy(&o.stderr));
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

/// ruby, and the directories of its headers (ruby.h and its config.h), when both are installed. On
/// Windows the flags an extension also needs follow them: a DLL links Ruby's own (no symbol is left
/// for the host to define), and Ruby's math declarations add a dllimport clang warns of
fn ruby_headers() -> Option<(PathBuf, Vec<String>)> {
    let ruby = local_tool("ruby", "-v")?;
    let o = Command::new(&ruby).args(["-e", "print RbConfig::CONFIG['rubyhdrdir'], ' ', RbConfig::CONFIG['rubyarchhdrdir']"]).output().ok()?;
    let mut dirs: Vec<String> = String::from_utf8_lossy(&o.stdout).split_whitespace().map(String::from).collect();
    if dirs.len() != 2 || !Path::new(&dirs[0]).join("ruby.h").is_file() {
        return None;
    }
    if cfg!(windows) {
        let o = Command::new(&ruby).args(["-e", "print '-L', RbConfig::CONFIG['libdir'], ' ', RbConfig::CONFIG['LIBRUBYARG_SHARED']"]).output().ok()?;
        dirs.extend(String::from_utf8_lossy(&o.stdout).split_whitespace().map(String::from));
        dirs.push("-Wno-dll-attribute-on-redeclaration".into());
    }
    Some((ruby, dirs))
}

/// cc building Ruby extension src against library lib (in lib_dir), with the leak report linked in
/// (it prints the library's live allocations at exit, once Ruby has freed its objects); -o next
fn ruby_ext(hdrs: &[String], src: &Path, lib_dir: &str, lib: &str) -> Command {
    let mut cc = Command::new("cc");
    cc.args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror"]).args(MODULE_FLAGS);
    for h in hdrs {
        if h.starts_with('-') { cc.arg(h) } else { cc.arg("-I").arg(h) };
    }
    cc.arg(src).args(["leak_report.c", "-L", lib_dir, &format!("-l{lib}"), &format!("-Wl,-rpath,{lib_dir}"), "-o"]);
    cc
}

/// a program linked against a shared library in dir (found through -rpath elsewhere): Windows looks
/// for the DLL on PATH
fn with_lib(mut c: Command, dir: &str) -> Command {
    if cfg!(windows) {
        let path = std::env::var_os("PATH").unwrap_or_default();
        c.env("PATH", std::env::join_paths(std::iter::once(PathBuf::from(dir)).chain(std::env::split_paths(&path))).unwrap());
    }
    c
}

/// a loadable module's link flags (Node's, Lua's, Ruby's): macOS's linker leaves the names the host
/// program defines to be found when the module loads only under -undefined dynamic_lookup
const MODULE_FLAGS: &[&str] = if cfg!(target_os = "macos") { &["-undefined", "dynamic_lookup"] } else { &[] };

fn run(cmd: &mut Command) -> Output {
    cmd.current_dir(Path::new(ROOT).join("tests/interop")).output().unwrap()
}

/// a shared library's file name as the platform names it (libNAME.so, libNAME.dylib, NAME.dll)
/// rustc's --target on Windows: the MinGW one the C compiler builds for (rustc's default there is
/// MSVC's, whose linker wants a .lib), as bolt's rust_target picks (llvm-mingw's clang says
/// x86_64-w64-windows-gnu, MinGW's gcc ...-mingw32); nothing elsewhere
fn rust_client_target() -> Vec<String> {
    if !cfg!(windows) {
        return Vec::new();
    }
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".into());
    let Ok(o) = Command::new(cc).arg("-dumpmachine").output() else { return Vec::new() };
    let m = String::from_utf8_lossy(&o.stdout).trim().to_string();
    let arch = m.split('-').next().unwrap_or("x86_64").to_string();
    vec!["--target".into(), format!("{arch}-pc-windows-{}", if m.ends_with("mingw32") { "gnu" } else { "gnullvm" })]
}

fn dylib(name: &str) -> String {
    format!("{}{name}.{}", std::env::consts::DLL_PREFIX, std::env::consts::DLL_EXTENSION)
}

/// a Ruby extension's file name (Ruby's DLEXT: .bundle on macOS, .so elsewhere)
fn ruby_module(name: &str) -> String {
    format!("{name}.{}", if cfg!(target_os = "macos") { "bundle" } else { "so" })
}

#[test]
fn bindings_round_trip() {
    let e = Env::new("bindings");
    let pkg = "mathlib=mathlib/lib";
    for backend in ["c", "llvm"] {
        let so = e.path(&format!("{backend}/{}", dylib("mathlib")));
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
        assert_eq!(ok(with_lib(Command::new(bin("c_shared")), &lib_dir).output().unwrap(), "C program"), MATHLIB_OUT, "C, shared ({backend})");
        ok(run(Command::new("cc").args(["client.c", "-I", &e.path("")]).arg(format!("{lib_dir}/libmathlib_static.a")).arg("-o").arg(bin("c_static"))), "cc client.c (static)");
        assert_eq!(ok(Command::new(bin("c_static")).output().unwrap(), "C program (static)"), MATHLIB_OUT, "C, static ({backend})");
        // C++
        ok(run(Command::new("c++").args(["-std=c++17", "client.cpp", "-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(bin("cpp"))), "c++ client.cpp");
        assert_eq!(ok(with_lib(Command::new(bin("cpp")), &lib_dir).output().unwrap(), "C++ program"), MATHLIB_OUT, "C++ ({backend})");
        // Rust: client.rs next to its mathlib.rs module
        std::fs::copy(Path::new(ROOT).join("tests/interop/client.rs"), e.dir.join("client.rs")).unwrap();
        ok(run(Command::new("rustc").args(rust_client_target()).arg(e.dir.join("client.rs")).args(["--edition", "2021", "-L", &lib_dir, "-l", "mathlib", "-C", &format!("link-arg={rpath}"), "-o"]).arg(bin("rs"))), "rustc client.rs");
        assert_eq!(ok(with_lib(Command::new(bin("rs")), &lib_dir).output().unwrap(), "Rust program"), MATHLIB_OUT, "Rust ({backend})");
        // Python: the module loads the library from $VOLT_MATHLIB_LIB, else next to itself
        let py = run(Command::new("python3").arg("client.py").env("PYTHONPATH", e.path("")).env("VOLT_MATHLIB_LIB", format!("{lib_dir}/{}", dylib("mathlib"))));
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
                ok(run(Command::new("cc").args(["-shared", "-fPIC", "-Wall", "-Werror", "-I", &inc]).args(MODULE_FLAGS).arg(e.dir.join("mathlib_node.c")).args(["-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(e.dir.join("mathlib.node"))), "cc mathlib_node.c");
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
                let want = "too big for i32 RangeError\nNaN TypeError\nInfinity TypeError\nfraction for i32 TypeError\nstring for a number TypeError\nnot a counter TypeError\nclosed counter TypeError\nbigint 2\nworker 2 3\n";
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
                let o = Command::new(&dotnet).args(["run", "--nologo"]).current_dir(&proj).env("LD_LIBRARY_PATH", &lib_dir).env("DYLD_LIBRARY_PATH", &lib_dir).env("PATH", common::path_with(&lib_dir)).env("DOTNET_CLI_TELEMETRY_OPTOUT", "1").env("DOTNET_NOLOGO", "1").env("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1").output().unwrap();
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
                let o = Command::new(bin.join("java")).args(["--enable-native-access=ALL-UNNAMED", "-cp", "classes", "Client"]).current_dir(&jdir).env("LD_LIBRARY_PATH", &lib_dir).env("DYLD_LIBRARY_PATH", &lib_dir).output().unwrap();
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
            // (PATH: Windows finds the library's DLL there, not by rpath)
            let go = |args: &[&str]| Command::new("go").args(args).current_dir(&gdir).env("CGO_LDFLAGS", &flags).env("GOFLAGS", "-mod=mod").env("GOPROXY", "off").env("PATH", common::path_with(&lib_dir)).output().unwrap();
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
            ok(run(Command::new("cc").args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-I", inc]).args(MODULE_FLAGS).arg(e.dir.join("mathlib_lua.c")).args(["-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(ldir.join("mathlib.so"))), "cc mathlib_lua.c");
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
            let o = Command::new(&dart).args(["run", "client.dart"]).current_dir(&ddir).env("VOLT_MATHLIB_LIB", format!("{lib_dir}/{}", dylib("mathlib"))).output().unwrap();
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
                cc.args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror"]).args(MODULE_FLAGS);
                for h in &hdrs {
                    if h.starts_with('-') { cc.arg(h) } else { cc.arg("-I").arg(h) };
                }
                ok(run(cc.arg(e.dir.join("mathlib_ruby.c")).args(["-I", &e.path(""), "-L", &lib_dir, "-lmathlib", &rpath, "-o"]).arg(rdir.join(ruby_module("mathlib")))), "cc mathlib_ruby.c");
                // RubyInstaller's ruby looks for an extension's DLLs on RUBY_DLL_PATH, not PATH
                let o = Command::new(&ruby).arg("-I").arg(&rdir).arg(Path::new(ROOT).join("tests/interop/client.rb")).env("RUBY_DLL_PATH", &lib_dir).output().unwrap();
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
            let z = Command::new(zig).args(["run", "client.zig"]).args(&target).args(["-lc", "-L", &lib_dir, "-lmathlib"]).current_dir(&e.dir).env("LD_LIBRARY_PATH", &lib_dir).env("DYLD_LIBRARY_PATH", &lib_dir).output().unwrap();
            assert!(z.status.success(), "zig run: {}", String::from_utf8_lossy(&z.stderr));
            assert_eq!(String::from_utf8_lossy(&z.stderr), MATHLIB_OUT, "Zig ({backend})");
        } else {
            eprintln!("zig isn't installed: skipping the Zig client");
        }
    }
    // bolt builds them too: [lib] kind and bindings
    let pkg_dir = e.dir.join("pkg");
    std::fs::create_dir_all(pkg_dir.join("lib")).unwrap();
    std::fs::write(pkg_dir.join("bolt.toml"), "[package]\nname = \"twice\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"volt\", \"shared\", \"static\"]\nbindings = [\"c\", \"python\", \"node\", \"js\", \"ts\", \"lua\", \"ruby\", \"swift\", \"kotlin\"]\n\n[std]\npath = \"STD\"\n".replace("STD", &Path::new(ROOT).join("std").display().to_string().replace('\\', "/"))).unwrap();
    std::fs::write(pkg_dir.join("lib/twice.volt"), "export fn twice(x: i32) -> i32 { return x * 2; }\n").unwrap();
    // ~/.local/bin on the PATH, where a downloaded ruby goes
    let path = std::env::var("PATH").unwrap_or_default();
    let path = std::env::var("HOME").map(|h| format!("{h}/.local/bin:{path}")).unwrap_or(path);
    let b = Command::new(env!("CARGO_BIN_EXE_bolt")).arg("build").current_dir(&pkg_dir).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("PATH", &path).output().unwrap();
    assert!(b.status.success(), "bolt build: {}", String::from_utf8_lossy(&b.stderr));
    for f in [dylib("twice").as_str(), "libtwice.a", "deps/libtwice.a", "bindings/twice.h", "bindings/twice.py", "bindings/twice_node.c", "bindings/twice.js", "bindings/twice.d.ts", "bindings/twice_lua.c", "bindings/twice_ruby.c", "bindings/twice.swift", "bindings/Ctwice/module.modulemap", "bindings/twice.kt", "bindings/twice.def"] {
        assert!(pkg_dir.join("target/debug").join(f).is_file(), "bolt didn't make target/debug/{f}");
    }
    // the native modules it compiled load as they are, from target/
    let bindings = pkg_dir.join("target/debug/bindings");
    // Python's default library name follows the platform (the loader records it instead of loading)
    let check = "import ctypes, os, sys\nseen = []\ndef cdll(p, *a, **k):\n    seen.append(os.path.basename(p))\n    raise OSError\nctypes.CDLL = cdll\nfor sys.platform in ['darwin', 'win32', 'linux']:\n    sys.modules.pop('twice', None)\n    try:\n        import twice\n    except OSError:\n        pass\nprint(*seen)\n";
    let o = Command::new("python3").args(["-c", check]).current_dir(&bindings).env_remove("VOLT_TWICE_LIB").output().unwrap();
    assert_eq!(ok(o, "python3 (twice.py's library name)"), "libtwice.dylib twice.dll libtwice.so\n", "twice.py's default library");
    // and it finds bolt's library one directory up, with no $VOLT_TWICE_LIB
    let o = Command::new("python3").args(["-c", "import twice; print(twice.twice(21))"]).current_dir(&bindings).env_remove("VOLT_TWICE_LIB").output().unwrap();
    assert_eq!(ok(o, "python3 (bolt's twice.py)"), "42\n", "twice.py loads target/debug's library");
    if node_include().is_some() {
        let o = Command::new("node").args(["-e", "console.log(require('./twice.js').twice(21))"]).current_dir(&bindings).output().unwrap();
        assert_eq!(ok(o, "node (bolt's addon)"), "42\n", "bolt's Node addon");
    }
    if lua_include().is_some() {
        let o = Command::new("lua").args(["-e", "package.cpath = 'lua/?.so'; print(require('twice').twice(21))"]).current_dir(&bindings).output().unwrap();
        assert_eq!(ok(o, "lua (bolt's module)"), "42\n", "bolt's Lua module");
    }
    if let Some((ruby, _)) = ruby_headers() {
        let o = Command::new(ruby).args(["-I", "ruby", "-e", "require 'twice'; puts Twice.twice(21)"]).current_dir(&bindings).env("RUBY_DLL_PATH", pkg_dir.join("target/debug")).output().unwrap();
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
        // a slice of handles comes back as a list of copies: refused when they can't be copied
        ("export struct gadget { n: i32; }\nattach fn delete(this: gadget&) -> void {}\nexport fn bad_view(xs: gadget[..]) -> gadget[..] { return xs; }\n", "c", "gadget can't be copied"),
        // and as E!T's value
        ("export struct gadget { n: i32; }\nattach fn delete(this: gadget&) -> void {}\npublic error oops { BAD, }\nexport fn bad_view(xs: gadget[..]) -> oops!(gadget[..]) { return xs; }\n", "c", "gadget can't be copied"),
        // a callback's E! of a slice of text: nothing would own the copies
        ("use std::string;\npublic error oops { BAD, }\nexport fn bad_cb(f: fn(i32) -> oops!(std::string[..])) -> usize {\n    val xs = f(1) catch return 0;\n    return xs.len;\n}\n", "c", "has no C form"),
        // a SIMD vector crosses only as an export fn's own parameter or result (the array of its
        // lanes): in an optional, an E! or a callback it has no C form (a struct holding one is a
        // handle)
        ("use std::simd;\nexport fn opt(v: std::simd::f32x4?) -> i32 { return 1; }\n", "c", "has no C form"),
        ("use std::simd;\npublic error oops { BAD, }\nexport fn maybe(x: i32) -> oops!std::simd::f32x4 { return std::simd::splat<std::simd::f32x4>(1.0); }\n", "c", "has no C form"),
        ("use std::simd;\nexport fn cb(f: fn(std::simd::i32x4) -> i32) -> i32 { return f({}); }\n", "c", "has no C form"),
        // handles in a slice a Python function gives back: nothing would lend them
        ("export struct gadget { n: i32; }\nexport fn bad_cb(f: fn(i32) -> gadget*[..]) -> usize { return f(1).len; }\n", "python", "nothing would lend the handles"),
    ] {
        std::fs::write(bad.join("bad.volt"), src).unwrap();
        let o = e.voltc(&["bindings", "bad", "--pkg", &format!("bad={}", bad.display()), "--lang", lang]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains(want), "{err}");
    }
    // a slice of E! over text or handles: Volt holds the value itself, C would read { error, its
    // C form }, so voltc lib refuses it as a parameter and as a result
    for (src, want) in [
        ("use std::string;\npublic error oops { BAD, }\nexport fn f(xs: oops!std::string[..]) -> usize { return xs.len; }\n", "oops!std::string"),
        ("export struct badge { n: i32; }\npublic error oops { BAD, }\npublic struct box { xs: std::vec<oops!badge>; }\nexport fn box_new() -> box { return { xs: {} }; }\nexport attach fn all(this: box&) -> oops!badge[..] { return this.xs.items(); }\n", "oops!badge"),
    ] {
        std::fs::write(bad.join("bad.volt"), src).unwrap();
        let o = e.voltc(&["lib", "bad", "--pkg", &format!("bad={}", bad.display()), "--static", "-o", &e.path("libbad.a")]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains("has no C form") && err.contains(want), "{err}");
    }
    // over numbers or str it keeps its form
    std::fs::write(bad.join("bad.volt"), "public error oops { BAD, }\nexport fn f(xs: oops!i32[..], ys: oops!str[..]) -> usize { return xs.len + ys.len; }\n").unwrap();
    ok(e.voltc(&["lib", "bad", "--pkg", &format!("bad={}", bad.display()), "--static", "-o", &e.path("libbad.a")]), "voltc lib of a slice of E!i32 and of E!str");

    // the shims' temporaries never take a parameter's name: viewed_ and item_ are what a slice given
    // back as a list of copies (bare or in an E!) is copied with; x_v, x_f, cb_user and this_ what
    // a slice of text, a trait, a closure and an attached fn's this are taken with, and a0 the
    // closure's relay's own parameter
    let names = e.dir.join("names");
    std::fs::create_dir_all(&names).unwrap();
    std::fs::write(names.join("names.volt"), "use std::string;\n\npublic error oops {\n    BACKWARDS,\n}\n\npublic struct shelf {\n    xs: std::vec<std::string>;\n}\n\nexport fn shelf_new() -> shelf {\n    var s: shelf = { xs: {} };\n    s.xs.push(std::string::from(\"a\")) catch @panic(\"out of memory\");\n    s.xs.push(std::string::from(\"b\")) catch @panic(\"out of memory\");\n    s.xs.push(std::string::from(\"c\")) catch @panic(\"out of memory\");\n    return s;\n}\n\nexport attach fn between(this: shelf&, viewed_: usize, item_: usize) -> std::string[..] {\n    return this.xs.items()[viewed_..item_];\n}\n\nexport attach fn between_or(this: shelf&, viewed_: usize, item_: usize) -> oops!(std::string[..]) {\n    if (viewed_ > item_) {\n        return oops::BACKWARDS;\n    }\n    return this.xs.items()[viewed_..item_];\n}\n\nexport attach fn plus(this: shelf&, this_: usize) -> usize {\n    return this.xs.len + this_;\n}\n\npublic trait counter {\n    fn count(this) -> i32;\n}\n\nexport fn counted(x: counter&, x_f: i32, x_v: i32) -> i32 {\n    return x.count() + x_f + x_v;\n}\n\nexport fn summed(x: std::string[..], x_v: usize) -> usize {\n    var t = x_v;\n    for (s&) in x {\n        t += s.len();\n    }\n    return t;\n}\n\nexport fn applied(cb: fn(i32) -> i32, cb_user: i32) -> i32 {\n    return cb(cb_user);\n}\n\nexport fn first(a0: fn(i32) -> i32, n: i32) -> i32 {\n    return a0(n);\n}\n").unwrap();
    let npkg = format!("names={}", names.display());
    ok(e.voltc(&["lib", "names", "--pkg", &npkg, "--shared", "--leak-check", "-o", &e.path(&dylib("names"))]), "voltc lib names --shared");
    ok(e.voltc(&["bindings", "names", "--pkg", &npkg, "--lang", "c", "-o", &e.path("names.h")]), "voltc bindings names --lang c");
    std::fs::write(e.dir.join("names_main.c"), "#include \"names.h\"\n#include <stdio.h>\n\nextern size_t volt_live_allocs;\n\n#define TEXT(t) (int)(t).len, (const char *)(t).ptr\n\nstatic int32_t count_it(void *self) {\n    return *(int32_t *)self;\n}\n\nstatic const names_counter_vt counter_vt = {count_it};\n\nstatic int32_t add_to(void *user, int32_t x) {\n    return x + *(int32_t *)user;\n}\n\nint main(void) {\n    names_shelf *s = shelf_new();\n    names_list_text l = shelf_between(s, 1, 3);\n    printf(\"%zu %.*s %.*s\", l.len, TEXT(l.ptr[0]), TEXT(l.ptr[1]));\n    volt_list_free(l);\n    names_oops_or_list_text r = shelf_between_or(s, 0, 1);\n    printf(\" %zu %.*s\", r.value.len, TEXT(r.value.ptr[0]));\n    volt_list_free(r.value);\n    r = shelf_between_or(s, 2, 1);\n    printf(\" %s\", r.error == NAMES_OOPS_BACKWARDS ? \"BACKWARDS\" : \"?\");\n    printf(\" %zu\", shelf_plus(s, 7));\n    int32_t four = 4, ten = 10;\n    names_counter c = {&counter_vt, &four, NULL};\n    printf(\" %d\", counted(c, 20, 300));\n    volt_str ws[] = {{(const uint8_t *)\"ab\", 2}, {(const uint8_t *)\"cde\", 3}};\n    names_slice_str wl = {ws, 2};\n    printf(\" %zu %d %d\", summed(wl, 100), applied(add_to, &ten, 5), first(add_to, &ten, 1));\n    shelf_free(s);\n    printf(\" live %zu\\n\", volt_live_allocs);\n    return 0;\n}\n").unwrap();
    let rpath = format!("-Wl,-rpath,{}", e.path(""));
    ok(Command::new("cc").args(["-Wall", "-Werror", "names_main.c", "-I", &e.path(""), "-L", &e.path(""), "-lnames", &rpath, "-o", "names_main"]).current_dir(&e.dir).output().unwrap(), "cc names_main.c");
    assert_eq!(ok(Command::new(e.dir.join("names_main")).output().unwrap(), "names_main"), "2 b c 1 a BACKWARDS 10 324 105 15 11 live 0\n", "a shim's temporaries and its parameters' names");
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
    ok(e.voltc(&["lib", "nested", "--pkg", &pkg, "--shared", "-o", &e.path(&dylib("nested"))]), "voltc lib nested --shared");
    ok(e.voltc(&["bindings", "nested", "--pkg", &pkg, "--lang", "c", "-o", &e.path("nested.h")]), "voltc bindings nested --lang c");
    std::fs::write(e.dir.join("main.c"), "#include \"nested.h\"\n#include <stdio.h>\n\nint main(void) {\n    int64_t a[] = {1, 2}, b[] = {3};\n    nested_slice_i64 rows[] = {{a, 2}, {b, 1}};\n    printf(\"%lld\\n\", (long long)total((nested_slice_slice_i64){rows, 2}));\n    nested_thing *ts[] = {thing_new(2), thing_new(5)};\n    nested_thing *ms[] = {ts[0], NULL, ts[1]};\n    printf(\"%lld %lld\\n\", (long long)sum_lent((nested_slice_nested_thing){ts, 2}), (long long)sum_maybe((nested_slice_nested_thing){ms, 3}));\n    thing_free(ts[0]);\n    thing_free(ts[1]);\n    return 0;\n}\n").unwrap();
    let rpath = format!("-Wl,-rpath,{}", e.path(""));
    ok(Command::new("cc").args(["-Wall", "-Werror", "main.c", "-I", &e.path(""), "-L", &e.path(""), "-lnested", &rpath, "-o", "main"]).current_dir(&e.dir).output().unwrap(), "cc main.c");
    assert_eq!(ok(Command::new(e.dir.join("main")).output().unwrap(), "main"), "6\n7 7\n");
}

// a header struct whose Volt fields aren't its C layout (packed, an aligned member: cimport placed
// them by C's offsets; a union; a bitfield) has no C form in bindings, which declare a struct from
// those fields; a plain one keeps its form, and a pointer to a refused one is an opaque void *
#[test]
fn bindings_header_layouts() {
    let e = Env::new("hdrlayout");
    let dir = e.dir.join("hl");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("hl.h"), "struct __attribute__((packed)) p1 { char c; int x; };\nstruct m1 { char c; int x __attribute__((aligned(16))); };\nunion u1 { int x; float f; };\nstruct bf { int a : 3; int x; };\nstruct plain { char c; int x; };\nstruct holder { struct p1 *p; int x; };\n").unwrap();
    let pkg = format!("hl={}", dir.display());
    for ty in ["p1", "m1", "u1", "bf"] {
        std::fs::write(dir.join("hl.volt"), format!("use {{ \"hl.h\" }} as c;\nexport fn take(p: c::{ty}) -> i32 {{ return @cast<i32>(p.x); }}\n")).unwrap();
        let o = e.voltc(&["bindings", "hl", "--pkg", &pkg, "--lang", "c"]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains("has no C form") && err.contains(ty), "{ty}: {err}");
    }
    std::fs::write(dir.join("hl.volt"), "use { \"hl.h\" } as c;\nexport fn take(p: c::plain) -> i32 { return p.x; }\n").unwrap();
    ok(e.voltc(&["bindings", "hl", "--pkg", &pkg, "--lang", "c"]), "voltc bindings of a plain header struct");
    // a plain struct pointing at a packed one stays a by-value struct (not a handle)
    std::fs::write(dir.join("hl.volt"), "use { \"hl.h\" } as c;\nexport fn take(h: c::holder) -> i32 { return h.x; }\n").unwrap();
    let h = ok(e.voltc(&["bindings", "hl", "--pkg", &pkg, "--lang", "c"]), "voltc bindings of a struct pointing at a packed one");
    assert!(h.contains("take(hl_c_holder h)") && h.contains("void *p;"), "{h}");
}

const SHAPES_OUT: &str = "biggest 9 1.5\naccount bea 300\nvisit 301 get 301\nclosed 301 1\ncircle of area 3\ncircle gone\ngrown 27\nsquare 9 square of area 9\nhey!\ntry 4 OVERDRAWN\nopened 25\nclosed 2\n42 hello, volt\nowners 2 ann bobby\nrichest 9 after 6 10\nopened 2 dee\nroster ann bo ann bo ann! bo!\nor ann! bo! ann! bo! OVERDRAWN OVERDRAWN\nsquares 4 16 sum 30\njoined a-b-c total 3\nhello, ann; hello, nobody\nnick 1 ann 0\nopen_if 1 1\nclose_if 0 -1\nclose_all 2\nsome 2\nrows 6\narrays 12 13 11 2.5 1.5 2 3 4\ntagged 41 5 20 7 8 127\nlists closed 7\ncircle gone\n";

#[test]
fn bindings_shapes() {
    // what every language calls beyond the plain shapes: a generic's instances, a struct that owns text
    // held by a handle with its methods, owned values passed in, a trait implemented on either side,
    // closures taking and giving text and handles, closures given back, slices of text and handles
    // given back (as lists of copies, freed before Volt changes its own). The library is a
    // leak-checked build, and leak_report.c (or the client) prints how many of its allocations are
    // live when the client is done
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
        ok(e.voltc(&["lib", "shapelib", "--pkg", pkg, "--shared", "--leak-check", "--backend", backend, "-o", &format!("{lib}/{}", dylib("shapelib"))]), "voltc lib --shared");
        let rpath = format!("-Wl,-rpath,{lib}");
        for (cc, std, client) in [("cc", "-std=c11", "client_shapes.c"), ("c++", "-std=c++17", "client_shapes.cpp")] {
            let bin = e.dir.join(format!("{backend}_{cc}"));
            // the leak report as its object: clang++ refuses C source in C++ mode (-Wdeprecated)
            ok(run(Command::new(cc).args([std, "-Wall", "-Werror", client, &e.path("leak_report.o"), "-I", &e.path(""), "-L", &lib, "-lshapelib", &rpath, "-o"]).arg(&bin)), &format!("{cc} {client}"));
            let o = with_lib(Command::new(&bin), &lib).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "{client} ({backend}): the library's allocations at exit ({}, {} bytes out)", o.status, o.stdout.len());
            assert_eq!(ok(o, client), SHAPES_OUT, "{client} ({backend})");
        }
        let bin = e.dir.join(format!("{backend}_rs"));
        ok(run(Command::new("rustc").args(rust_client_target()).arg(e.dir.join("client_shapes.rs")).args(["--edition", "2021", "-L", &lib, "-l", "shapelib", "-C"]).arg(format!("link-arg={}", e.path("leak_report.o"))).args(["-C", &format!("link-arg={rpath}"), "-o"]).arg(&bin)), "rustc client_shapes.rs");
        let o = with_lib(Command::new(&bin), &lib).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.rs ({backend}): the library's allocations at exit");
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
            let z = Command::new(zig).args(["run", "client_shapes.zig", "leak_report.c"]).args(&target).args(["-lc", "-L", &lib, "-lshapelib"]).current_dir(&e.dir).env("LD_LIBRARY_PATH", &lib).env("DYLD_LIBRARY_PATH", &lib).output().unwrap();
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
                let o = Command::new(bin.join("java")).args(["--enable-native-access=ALL-UNNAMED", "-cp", "classes", "ClientShapes"]).current_dir(&jdir).env("LD_LIBRARY_PATH", &lib).env("DYLD_LIBRARY_PATH", &lib).output().unwrap();
                assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "ClientShapes.java ({backend}): the library's allocations at exit");
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
            let o = Command::new(&dotnet).args(["run", "--nologo"]).current_dir(&proj).env("LD_LIBRARY_PATH", &lib).env("DYLD_LIBRARY_PATH", &lib).env("PATH", common::path_with(&lib)).env("DOTNET_CLI_TELEMETRY_OPTOUT", "1").env("DOTNET_NOLOGO", "1").env("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1").output().unwrap();
            // (Console.Error.WriteLine ends a line with \r\n on Windows)
            let err = String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n");
            let out = ok(o, "dotnet run client_shapes.cs");
            assert_eq!(err, "volt live: 0\n", "client_shapes.cs ({backend}): the library's allocations at exit");
            assert_eq!(out, format!("checked true OVERDRAWN\nlimit true OVERDRAWN\nsign positive not positive\n{SHAPES_OUT}"), "client_shapes.cs ({backend})");
        } else {
            eprintln!("dotnet isn't installed: skipping the C# shapes client");
        }
        // Python: client_shapes.py with shapelib.py, printing the library's leak report itself (and
        // after the rest, what only Python checks: callbacks' exceptions, what Volt can't take)
        let py = Command::new("python3").arg(Path::new(ROOT).join("tests/interop/client_shapes.py")).env("PYTHONPATH", e.path("")).env("VOLT_SHAPELIB_LIB", format!("{lib}/{}", dylib("shapelib"))).output().unwrap();
        // (Python's stderr is text: \r\n on Windows)
        assert_eq!(String::from_utf8_lossy(&py.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.py ({backend}): the library's allocations at exit");
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
            let go = |args: &[&str]| Command::new("go").args(args).current_dir(&gdir).env("CGO_LDFLAGS", &flags).env("GOFLAGS", "-mod=mod").env("GOPROXY", "off").env("PATH", common::path_with(&lib)).output().unwrap();
            let unformatted = ok(Command::new("gofmt").args(["-l", "."]).current_dir(&gdir).output().unwrap(), "gofmt -l");
            assert_eq!(unformatted, "", "gofmt would change these ({backend})");
            ok(go(&["vet", "./..."]), "go vet (shapes)");
            ok(go(&["build", "-o", "client", "."]), "go build (shapes)");
            let o = Command::new(gdir.join("client")).env("PATH", common::path_with(&lib)).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.go ({backend}): the library's allocations at exit");
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
                ok(run(Command::new("cc").args(["-shared", "-fPIC", "-I", &inc]).args(MODULE_FLAGS).arg(e.dir.join("shapelib_node.c")).args(["leak_report.c", "-L", &lib, "-lshapelib", &rpath, "-o"]).arg(ndir.join("shapelib.node"))), "cc shapelib_node.c");
                let o = Command::new("node").arg("client_shapes.js").current_dir(&ndir).output().unwrap();
                assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.js ({backend}): the library's allocations at exit");
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
            ok(run(Command::new("cc").args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-I", inc]).args(MODULE_FLAGS).arg(e.dir.join("shapelib_lua.c")).args(["leak_report.c", "-I", &e.path(""), "-L", &lib, "-lshapelib", &rpath, "-o"]).arg(ldir.join("shapelib.so"))), "cc shapelib_lua.c");
            let o = Command::new("lua").arg(Path::new(ROOT).join("tests/interop/client_shapes.lua")).env("LUA_CPATH", ldir.join("?.so")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.lua ({backend}): the library's allocations at exit");
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
                ok(run(ruby_ext(&hdrs, &e.dir.join("shapelib_ruby.c"), &lib, "shapelib").arg(rdir.join(ruby_module("shapelib")))), "cc shapelib_ruby.c");
                let o = Command::new(&ruby).arg("-I").arg(&rdir).arg(Path::new(ROOT).join("tests/interop/client_shapes.rb")).env("RUBY_DLL_PATH", &lib).output().unwrap();
                assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.rb ({backend}): the library's allocations at exit");
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
            let o = Command::new(&dart).args(["run", "client_shapes.dart"]).current_dir(&ddir).env("VOLT_SHAPELIB_LIB", format!("{lib}/{}", dylib("shapelib"))).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.dart ({backend}): the library's allocations at exit");
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
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.swift ({backend}): the library's allocations at exit");
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
            ok(e.voltc(&["lib", "swiftedge", "--pkg", epkg, "--shared", "--leak-check", "--backend", backend, "-o", &format!("{elib}/{}", dylib("swiftedge"))]), "voltc lib swiftedge");
            std::fs::write(edir.join("Cswiftedge/module.modulemap"), "module Cswiftedge {\n    header \"swiftedge.h\"\n    export *\n}\n").unwrap();
            std::fs::copy(Path::new(ROOT).join("tests/interop/client_swiftedge.swift"), edir.join("main.swift")).unwrap();
            let o = Command::new(&swiftc).args(["-warnings-as-errors", "-I", "Cswiftedge", "swiftedge.swift", "main.swift"]).arg(e.dir.join("leak_report.o")).args(["-L", &elib, "-lswiftedge", "-Xlinker", "-rpath", "-Xlinker", &elib, "-o", "client"]).current_dir(&edir).output().unwrap();
            ok(o, "swiftc client_swiftedge.swift");
            let o = Command::new(edir.join("client")).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_swiftedge.swift ({backend}): the library's allocations at exit");
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
            let o = Command::new(kdir.join("client.kexe")).env("LD_LIBRARY_PATH", &lib).env("DYLD_LIBRARY_PATH", &lib).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_shapes.kt ({backend}): the library's allocations at exit");
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
    ok(e.voltc(&["lib", "pyopt", "--pkg", &opkg, "--shared", "--leak-check", "-o", &e.path(&dylib("pyopt"))]), "voltc lib pyopt --shared");
    let check = "import ctypes, pyopt as p\nprint(p.count_text(['ab', None, 'c']), p.sum_things([p.thing(2), None, p.thing(5)]))\nprint(ctypes.c_size_t.in_dll(p._lib, 'volt_live_allocs').value)\n";
    let o = Command::new("python3").args(["-c", check]).env("PYTHONPATH", e.path("")).env("VOLT_PYOPT_LIB", e.path(&dylib("pyopt"))).output().unwrap();
    assert_eq!(ok(o, "python3 (pyopt)"), "3 7\n0\n", "Python: optionals of text and handles in slices");
    // Ruby: the same, nil for none (the leak report linked into the extension)
    if let Some((ruby, hdrs)) = ruby_headers() {
        ok(e.voltc(&["bindings", "pyopt", "--pkg", &opkg, "--lang", "ruby", "-o", &e.path("pyopt_ruby.c")]), "voltc bindings pyopt --lang ruby");
        let rdir = e.dir.join("ruby-pyopt");
        std::fs::create_dir_all(&rdir).unwrap();
        ok(run(ruby_ext(&hdrs, &e.dir.join("pyopt_ruby.c"), &e.path(""), "pyopt").arg(rdir.join(ruby_module("pyopt")))), "cc pyopt_ruby.c");
        let o = Command::new(&ruby).arg("-I").arg(&rdir).env("RUBY_DLL_PATH", e.path("")).args(["-e", "require 'pyopt'; puts \"#{Pyopt.count_text(['ab', nil, 'c'])} #{Pyopt.sum_things([Pyopt::Thing.new(2), nil, Pyopt::Thing.new(5)])}\""]).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "Ruby (pyopt): the library's allocations at exit");
        assert_eq!(ok(o, "ruby (pyopt)"), "3 7\n", "Ruby: optionals of text and handles in slices");
        // what shapelib doesn't have: client_moreshapes.rb with moreshapes (a trait object Volt keeps
        // past the call, handles given to a callback, a str a callback gives, ...)
        let mpkg = "moreshapes=moreshapes/lib";
        ok(e.voltc(&["bindings", "moreshapes", "--pkg", mpkg, "--lang", "ruby", "-o", &e.path("moreshapes_ruby.c")]), "voltc bindings moreshapes --lang ruby");
        ok(e.voltc(&["lib", "moreshapes", "--pkg", mpkg, "--shared", "--leak-check", "-o", &e.path(&dylib("moreshapes"))]), "voltc lib moreshapes --shared");
        ok(run(ruby_ext(&hdrs, &e.dir.join("moreshapes_ruby.c"), &e.path(""), "moreshapes").arg(rdir.join(ruby_module("moreshapes")))), "cc moreshapes_ruby.c");
        let o = Command::new(&ruby).arg("-I").arg(&rdir).arg(Path::new(ROOT).join("tests/interop/client_moreshapes.rb")).env("RUBY_DLL_PATH", e.path("")).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_moreshapes.rb: the library's allocations at exit");
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
        ok(e.voltc(&["lib", "dartmore", "--pkg", &mpkg, "--shared", "--leak-check", "-o", &at(&dylib("dartmore"))]), "voltc lib dartmore --shared");
        let client = "import 'dart:ffi';\nimport 'dart:io';\n\nimport 'dartmore.dart';\n\nvoid main() {\n  final a = thing(2), b = thing(5);\n  print('${count_text(['ab', null, 'c'])} ${sum_things([a, null, b])} ${label((x) => 'n$x', 42)} ${pick(a, (t) => t)} ${total((xs) => xs.reduce((x, y) => x + y), 'ab', 'c')} ${run((x) => x + 1)}');\n  a.close();\n  b.close();\n  print(DynamicLibrary.open(Platform.environment['VOLT_DARTMORE_LIB']!).lookup<Size>('volt_live_allocs').value);\n}\n";
        std::fs::write(more.join("more.dart"), client).unwrap();
        ok(Command::new(&dart).args(["analyze", "--fatal-infos", "dartmore.dart", "more.dart"]).current_dir(&more).output().unwrap(), "dart analyze (dartmore)");
        let o = Command::new(&dart).args(["run", "more.dart"]).current_dir(&more).env("VOLT_DARTMORE_LIB", at(&dylib("dartmore"))).output().unwrap();
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
        ok(e.voltc(&["lib", "ktshapes", "--pkg", pkg, "--shared", "--leak-check", "--backend", backend, "-o", &format!("{lib}/{}", dylib("ktshapes"))]), "voltc lib ktshapes --shared");
        if backend == "c" {
            let link = format!("{} -L{lib} -lktshapes --allow-shlib-undefined", e.path("leak_report.o"));
            let o = k(&konanc, &["ktshapes.kt", "client_ktshapes.kt", "-l", "ktshapes_c.klib", "-linker-options", &link, "-o", "client"]);
            assert!(!String::from_utf8_lossy(&o.stderr).contains("warning:"), "kotlinc-native warns: {}", String::from_utf8_lossy(&o.stderr));
            ok(o, "kotlinc-native client_ktshapes.kt");
        }
        let o = Command::new(e.dir.join("client.kexe")).env("LD_LIBRARY_PATH", &lib).env("DYLD_LIBRARY_PATH", &lib).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&o.stderr).replace("\r\n", "\n"), "volt live: 0\n", "client_ktshapes.kt ({backend}): the library's allocations at exit");
        assert_eq!(ok(o, "client_ktshapes.kt"), "measure 50 kotlin\nsizer gone\nfixed 50 fixed\neach [0, 1, 2]\nfailed each 8\nclose_ 700 7\nshut\nlabel n7\nslice 6\nresult 5 9\nmaybe yes null\ncstr 5\nsome [1, null]\ngetter 8\nbig [5, 9]\nlend 8\ngive 7\nrec 14\nbumped 2 9 ab tag BLUE 1\nmade 6\ntotal2 6\ntext 3\nblues 2\nfirst_two [4, 5]\nmaybe_get 5 -1\nslice_back 3\nstr_result 4 -1 -1\ntext_in 4\nlist_or [a] BAD\nsizer_or fixed\ngone 18\n", "client_ktshapes.kt ({backend})");
    }
}

#[test]
fn volt_calls_rust_and_python() {
    let e = Env::new("out");
    // Windows: the GNU target $CC links (rustc's host there is MSVC's), with the libraries rustc names
    let mut rustc = Command::new("rustc");
    rustc.args(["--crate-type", "staticlib", "--edition", "2021", "-C", "panic=abort", "rust_lib.rs", "--print", "native-static-libs", "-o"]).arg(e.dir.join("librs.a"));
    rustc.args(rust_client_target());
    let made = run(&mut rustc);
    let libs: Vec<String> = String::from_utf8_lossy(&made.stderr).lines().filter_map(|l| l.split("native-static-libs:").nth(1)).flat_map(|l| l.split_whitespace().map(String::from).collect::<Vec<_>>()).collect();
    ok(made, "rustc --crate-type staticlib");
    let rs = e.path("librs.a");
    for backend in ["c", "llvm"] {
        let mut args = vec!["run", "uses_rust.volt", "--backend", backend, "--cc", &rs];
        for l in &libs {
            args.extend(["--cc", l.as_str()]);
        }
        let out = ok(e.voltc(&args), "voltc run uses_rust.volt");
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"py_app\"\nversion = \"0.1.0\"\n\n[dependencies]\npython = {{ path = '{}' }}\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("interop/python").display(), Path::new(ROOT).join("std").display())).unwrap();
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"java_app\"\nversion = \"0.1.0\"\n\n[dependencies]\njava = {{ path = '{}' }}\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("interop/java").display(), Path::new(ROOT).join("std").display())).unwrap();
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"dotnet_app\"\nversion = \"0.1.0\"\n\n[dependencies]\ndotnet = {{ path = '{}' }}\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("interop/dotnet").display(), Path::new(ROOT).join("std").display())).unwrap();
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
    let toml = std::fs::read_to_string(app.join("bolt.toml")).unwrap() + &format!("\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display());
    std::fs::write(app.join("bolt.toml"), toml).unwrap();
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["run", "-q", "--backend", backend]).current_dir(&app).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).env("GOTOOLCHAIN", "local").output().unwrap();
        assert!(o.status.success(), "bolt run ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(String::from_utf8_lossy(&o.stdout), "add 42\nsum 6.5\nupper VOLT\nwords 3\n", "Volt uses Go ({backend})");
    }
    let header = std::fs::read_to_string(app.join("target/debug/foreign/include/gomath.h")).unwrap();
    // (Windows' cgo writes extern __declspec(dllexport) int gm_add(...))
    assert!(header.contains("extern ") && header.contains("int gm_add(int a, int b);"), "{header}");
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"lua_app\"\nversion = \"0.1.0\"\n\n[dependencies]\nlua = {{ path = '{}' }}\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("interop/lua").display(), Path::new(ROOT).join("std").display())).unwrap();
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
        assert_eq!(ok(c.output().unwrap(), "voltc run generics.volt"), "largest 9 1.5\nrepeat 3 7 0.5\npick b 1\nscaled 3 6\nstack 2 5 volt 4,5\npoints 1 bigger 8\nconst 12 <5> <volt>\n", "generics ({backend})");
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
        assert_eq!(ok(c.output().unwrap(), "voltc run traits.volt"), "area 6 larger 6\ngrown 15\ntri of area 15 [T]\na blob of its own [B]\n(tri of area 15) (a blob of its own)\nrust 1 a square of side 1 circle 12\ncircle 12 C\nunion 12\ncanvas 18 tri,blob,square\ndrops 2 squares 2\n", "traits ({backend})");
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
    // tuples, arrays, 128-bit integers; a trait with an associated type (Source<i32>), a generic
    // trait, a supertrait's methods, an associated const; a fn a macro makes
    let expect = |prog: &str| -> String { std::fs::read_to_string(dir.join(prog)).unwrap().lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| format!("{l}\n")).collect() };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "more.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run more.volt"), expect("more.volt"), "more ({backend})");
    }
    let mut c = Command::new(&e.voltc);
    c.args(["check", "more.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std")).env("VOLT_SHOW_IMPORT", "1");
    tools(&mut c);
    let shown = String::from_utf8_lossy(&c.output().unwrap().stderr).to_string();
    // (a tuple as a trait's type argument attaches: Convert<(i32, i32)>, Pairs's Source and pairs'
    // dyn_Source_tup2_i32_i32)
    for what in ["Anchored::START (a const of a type Volt can't name)"] {
        assert!(shown.contains(what), "left out, with why: {what}\n{shown}");
    }
    // rustdoc unable to write its JSON: the crate is read from rustc's expanded source, so what a
    // macro makes is still there (a cache of its own: the import isn't the one rustdoc read)
    // (the generated declarations say where they came from: voltc keeps bolt's stderr to itself)
    let mut c = Command::new(&e.voltc);
    c.args(["check", "macro.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std")).env("VOLT_SHOW_IMPORT", "1");
    tools(&mut c);
    c.env("RUSTDOC", "false").env("VOLT_CACHE", e.dir.join("cache-nodoc"));
    let shown = String::from_utf8_lossy(&c.output().unwrap().stderr).to_string();
    assert!(shown.contains("was read from rustc's expanded source"), "{shown}");
    let mut c = Command::new(&e.voltc);
    c.args(["run", "macro.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    c.env("RUSTDOC", "false").env("VOLT_CACHE", e.dir.join("cache-nodoc"));
    assert_eq!(ok(c.output().unwrap(), "voltc run macro.volt"), expect("macro.volt"), "without rustdoc");
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    let want = "dist 5 norm 5\nscaled 6 8\n42 fastmath 10 1.5\nfirst QUIET\nsum 7\ndoubled 2 4 6\nsquares 4 last 16\njoin a-b-c\nfind 2 true\nor_default 5 -1\nparse 42\nbad ERROR(InvalidCharacter)\ndiv 3\nzero ERROR(DivisionByZero)\ncolor blue green\npixel 2 green\ntwice 42\nperimeter 7 10 name tri\nside 4\nmissing ERROR(NoSuchSide)\nlongest quad\nconsumed 2\nticks 2 3\nlargest 9 2.5\nbigger 8 2.5 times 21 scaled 20 -10\npair 7\nstack true true false total 3 pop 2 1 true\nflags true true\npacked 5 -60 -54 7 -2\nunion true 4 true 3 true\nheld 3 0\nkept 5 0\narea 48 6 round true false\nbits 7\nbits 1.5 2.5\nctx 5 true 50\nmaybe 100\nextern 5\n";
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("ZIG", &zig);
    };
    // (leak-checked: what Zig allocates is Volt's memory, so it's counted too)
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--leak-check", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
        // an import's library that only a later one's needs is still found (GNU ld reads each
        // archive once, in the order given)
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--leak-check", "--backend", backend, "order.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run order.volt"), "order 20\n", "voltc run order.volt ({backend})");
    }
    // the limit: a file with export fns, imported under two names and used through both, gives the
    // linker each of its C symbols twice
    let mut c = Command::new(&e.voltc);
    c.args(["run", "dup.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    assert!(!o.status.success() && String::from_utf8_lossy(&o.stderr).contains("zig_ext_add"), "two names, one file: {}", String::from_utf8_lossy(&o.stderr));
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
    let shown = String::from_utf8_lossy(&o.stderr);
    assert!(shown.contains("// Zig: pub fn scale(self: *Point, k: f64) void\nattach fn scale("), "the Zig signature above its Volt fn: {shown}");
    // an extern fn Volt can't declare as C's: left out, with why
    for why in ["zig_ext_len (an extern fn with a parameter of a type C doesn't have)", "zig_ext_naked (an extern fn with a calling convention other than C's)"] {
        assert!(shown.contains(why), "left out: {why}: {shown}");
    }
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), std::fs::read_to_string(dir.join("main.volt")).unwrap().replace("use { \"", "use { \"../../")).unwrap();
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
    if cfg!(all(windows, target_arch = "aarch64")) {
        // the program stops at start with an access violation (0xc0000005) and no output: T-0630
        eprintln!("Windows arm64: a program linking Go's c-archive doesn't start yet (T-0630): skipping use go");
        return;
    }
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    // a generic instance C# rejects is an error at the call, with the C# compiler's reason
    let mut c = Command::new(&e.voltc);
    c.args(["run", "generics_bad.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
    tools(&mut c);
    let o = c.output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("Max<geo::Shape>: .NET doesn't take these types") && err.contains("IComparable"), "a rejected instance: {err}");
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
    std::fs::write(app.join("src/main.volt"), src.replace("\"Geo.cs\"", "\"../../Geo.cs\"").replace("\"Generic.cs\"", "\"../../Generic.cs\"")).unwrap();
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    // an async function's rejection stops it too, and so does a promise that never settles
    for (prog, says) in [("rejects.volt", "Error: no"), ("never.volt", "never settled")] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", prog]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        let o = c.output().unwrap();
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(o.status.code() == Some(101) && err.contains(says), "{prog}: {:?} {err}", o.status);
    }
    // the same program in a bolt package
    let app = dir.join("app");
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    std::fs::write(app.join("bolt.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
    std::fs::write(pkg.join("bolt.toml"), format!("[package]\nname = \"geo\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"volt\", \"shared\"]\nbindings = [\"python\", \"pyi\", \"node\", \"js\", \"ts\"]\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display())).unwrap();
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
        // a venv's programs are in Scripts on Windows
        let vbin = venv.join(if cfg!(windows) { "Scripts" } else { "bin" });
        let mut c = Command::new(vbin.join("pip"));
        c.args(["install", "--no-index", "--disable-pip-version-check", "-q"]).arg(&pkg);
        tools(&mut c);
        ok(c.output().unwrap(), "pip install");
        let o = Command::new(vbin.join("python")).args(["-c", "import geo; print(geo.area(2.0, 3.5), geo.twice(21))"]).current_dir(&elsewhere).output().unwrap();
        assert_eq!(ok(o, "python (pip installed)"), "7.0 42\n", "Python calls the package pip installed");
        // from its sdist too, built somewhere else
        let o = Command::new(vbin.join("python")).args(["-c", "import sys, volt_build; print(volt_build.build_sdist(sys.argv[1]))"]).arg(&e.dir).current_dir(&pkg).output().unwrap();
        let sdist = e.dir.join(ok(o, "build_sdist").trim());
        let mut c = Command::new(vbin.join("pip"));
        c.args(["install", "--no-index", "--disable-pip-version-check", "-q", "--force-reinstall"]).arg(&sdist);
        tools(&mut c);
        ok(c.output().unwrap(), "pip install (sdist)");
        let o = Command::new(vbin.join("python")).args(["-c", "import geo; print(geo.twice(4))"]).current_dir(&elsewhere).output().unwrap();
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
    std::fs::write(pkg.join("bolt.toml"), format!("[package]\nname = \"addon\"\nversion = \"0.1.0\"\n\n[lib]\nkind = [\"shared\"]\n\n[dependencies]\nnode = {{ path = '{}' }}\n\n[std]\npath = '{}'\n", Path::new(ROOT).join("interop/node").display(), Path::new(ROOT).join("std").display())).unwrap();
    let want = "add 5.5\nhello, volt hello, 42\nsum 6.5\npoint {\"x\":3,\"y\":4,\"label\":\"point\",\"pair\":[3,4]}\napply 42 from volt\nthrown true volt says no\ncaught THROWN(js says no)\nkinds number string boolean null undefined object object function\n";
    for backend in ["c", "llvm"] {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["build", "-q", "--backend", backend]).current_dir(&pkg).env("VOLTC", &e.voltc).env("BOLT_HOME", e.dir.join("cache")).output().unwrap();
        assert!(o.status.success(), "bolt build ({backend}): {}", String::from_utf8_lossy(&o.stderr));
        let node_file = e.dir.join(format!("addon-{backend}.node"));
        std::fs::copy(pkg.join("target/debug").join(dylib("addon")), &node_file).unwrap();
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
    let toml = std::fs::read_to_string(app.join("bolt.toml")).unwrap() + &format!("\n[std]\npath = '{}'\n", Path::new(ROOT).join("std").display());
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
    std::fs::write(rs.join("Cargo.toml"), format!("[package]\nname = \"rsapp\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[build-dependencies]\nvolt-build = {{ path = '{}' }}\n", Path::new(ROOT).join("interop/rust/volt-build").display())).unwrap();
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
    let want = "[ok 5 boxy] clicks 202 shown true\n[lbl 5] 10 true\n[x 5 boxy] area 10 poke 41 id 7\nmine 5 log:xlbl true\npress 11 [knob] ring 60\ncount 1 2 level 4\nboxy 5 gone\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive.volt", "--backend", backend]), "voltc run cpp_derive.volt"), want, "C++ derive ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_derive.volt"], Some("c++ -fno-rtti")), "voltc run cpp_derive.volt (-fno-rtti)"), want, "C++ derive without RTTI");
    // a pure virtual method the Volt type doesn't override is a compile error naming it
    let hpp = Path::new(ROOT).join("tests/interop/widgets.hpp");
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct nothing {{ n: i32; }}\nfn main() -> void {{\n    val x: nothing = {{ n: 1 }};\n    val w = cpp::gui::Widget::derive(move x, \"a\");\n}}\n", hpp.display().to_string().replace('\\', "/"));
    std::fs::write(e.dir.join("cpp_derive_pure.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_derive_pure.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("has to override width, which is pure virtual"), "pure virtual: {err}");
    // so is one the class doesn't have, in the attach block
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct nothing {{ n: i32; }}\nattach cpp::gui::Widget -> nothing {{\n    fn width(this, self: cpp::gui::Widget&) -> i32 {{ return 1; }}\n    fn widht(this, self: cpp::gui::Widget&) -> i32 {{ return 2; }}\n}}\nfn main() -> void {{}}\n", hpp.display().to_string().replace('\\', "/"));
    std::fs::write(e.dir.join("cpp_derive_extra.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_derive_extra.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("'widht' isn't one of Widget's functions"), "not a virtual method: {err}");
    // and one whose self is another class (it would override nothing)
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct nothing {{ n: i32; }}\nattach cpp::gui::Button -> nothing {{\n    fn sound(this, self: cpp::gui::Button&) -> i32 {{ return 1; }}\n    fn press(this, self: cpp::gui::Widget&) -> i32 {{ return 2; }}\n}}\nfn main() -> void {{}}\n", hpp.display().to_string().replace('\\', "/"));
    std::fs::write(e.dir.join("cpp_derive_self.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_derive_self.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("'press' takes a cpp::gui::Widget& as argument 1 here but a cpp::gui::Button& in 'Button'"), "another self: {err}");
    // a protected && method is left out, saying why
    let shown = Command::new(&e.voltc).args(["check", "cpp_derive.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("// left out: int gui::Widget::take() && (an && method: its object is the one a Volt type subclasses"), "a protected && method: {src}");
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
    // macOS x86-64 (the job's own LLVM with Apple's libc++): v.push_back on the std::vector a
    // virtual is handed misses its instance (T-0660): reported, not failed, until that's fixed
    if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        let o = e.voltc(&["run", "cpp_derive2.volt", "--backend", "c"]);
        if !o.status.success() {
            common::known_failure("cpp_derive_any: fails on macOS x86-64 (T-0660)", &String::from_utf8_lossy(&o.stderr));
            return;
        }
    }
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive2.volt", "--backend", backend]), "voltc run cpp_derive2.volt"), want, "C++ derive, any types ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_derive2.volt"], Some("c++ -fno-rtti")), "voltc run cpp_derive2.volt (-fno-rtti)"), want, "C++ derive, any types, without RTTI");
}

#[test]
fn cpp_derive3() {
    // a Volt subclass overriding virtual methods that take a std::string&, give back a reference,
    // are overloads of one name (draw, draw_double), &-qualified or private; a type overriding
    // none keeps C++'s own (the private one too); a class whose pure virtual methods take a
    // std::string& or are private can be derived from; with or without RTTI
    let e = Env::new("cpp-derive3");
    let want = "x-volt 15 202 7\n3007 2 190 n 15\nx-base 5 100 3\n2003 1 10\nmid 6003\ntwo 52 16 78 12\nshy 19\nin-sunk/42\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive3.volt", "--backend", backend]), "voltc run cpp_derive3.volt"), want, "C++ derive, references ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_derive3.volt"], Some("c++ -fno-rtti")), "voltc run cpp_derive3.volt (-fno-rtti)"), want, "C++ derive, references, without RTTI");
    // under C++11 and C++14 imports too
    for std in ["-std=c++11", "-std=c++14"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive3.volt", "--cc", std]), "voltc run cpp_derive3.volt"), want, "C++ derive, references ({std})");
    }
    // an && method is overridable too (cpp_derive6): the type here keeps C++'s own
    let shown = Command::new(&e.voltc).args(["check", "cpp_derive3.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("fn gone(this, self: Base&) -> i32;"), "an && virtual: {src}");
}

#[test]
fn cpp_derive6() {
    // a Volt subclass overriding virtual operators (op_eq, op_call), an && method and C variadic
    // virtuals (a void* to the call's va_list); a type overriding only the pure variadic one keeps
    // C++'s own for the rest
    let e = Env::new("cpp-derive6");
    let want = "all 1 30 42 7 6\nfew 0 7 1 -1 3\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive6.volt", "--backend", backend]), "voltc run cpp_derive6.volt"), want, "C++ derive, operators, && and variadic ({backend})");
    }
}

#[test]
fn cpp_derive5() {
    // a Volt subclass of a class whose virtual methods have types Volt has no form for: a
    // pointer-to-member parameter reaches the override as a void*, and a pure virtual whose result
    // has none doesn't keep Volt types from deriving (C++'s call of it throws)
    let e = Env::new("cpp-derive5");
    let want = "used 1607\nask threw\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive5.volt", "--backend", backend]), "voltc run cpp_derive5.volt"), want, "C++ derive, types with no Volt form ({backend})");
    }
}

#[test]
fn cpp_derive4() {
    // a Volt subclass overriding the & twin of a virtual method declared after its && one, the
    // later of two overloads differing only in const by its _const or _nonconst name, and the
    // virtual d_double beside a d(double) whose suffixed name that is (it stays C++'s, saying
    // why); built by the default $CXX and by clang++
    let e = Env::new("cpp-derive4");
    let want = "70 2030 4050 61072 810290 8\n10 203 405 1003 10204 5\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_derive4.volt", "--backend", backend]), "voltc run cpp_derive4.volt"), want, "C++ derive, twins ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_derive4.volt"], Some("clang++")), "voltc run cpp_derive4.volt (clang++)"), want, "C++ derive, twins, by clang++");
    let shown = Command::new(&e.voltc).args(["check", "cpp_derive4.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("// (d4::Q::d is C++'s own in a Volt type deriving from it: an overload, and d_double is taken)"), "a taken suffixed name: {src}");
    assert!(src.contains("fn g_rvalue(this, self: Q&) -> i32;"), "the && twin, g_rvalue: {src}");
    // a reference to a class held by handle, given back from an empty handle, stops the program
    // saying so
    let hpp = Path::new(ROOT).join("tests/interop/derive4.hpp");
    let src = format!("use {{ \"{}\" }} as cpp;\nstruct held {{ it: cpp::d4::Item; }}\nattach cpp::d4::Q -> held {{\n    fn pick(this, self: cpp::d4::Q&) -> cpp::d4::Item& {{ return &this.it; }}\n}}\nfn main() -> void {{\n    val h: held = {{ it: {{ cpp: null, borrowed: true }} }};\n    var q = cpp::d4::Q::derive(move h);\n    val n = cpp::d4::use_pick(&q);\n}}\n", hpp.display().to_string().replace('\\', "/"));
    std::fs::write(e.dir.join("cpp_derive_empty.volt"), src).unwrap();
    let o = e.voltc(&["run", &e.path("cpp_derive_empty.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(o.status.code() == Some(101) && err.contains("a C++ object Volt holds by handle was never made (its handle is empty)"), "an empty handle's reference: {:?} {err}", o.status);
}

#[test]
fn cpp_module() {
    // a C++20 named module (its interface imports std) and a header doing `import std;`: read by
    // libclang from clang-precompiled modules, built by $CXX its own way (g++'s module mapper,
    // clang's -fmodule-file); what the module doesn't export isn't there
    let e = Env::new("cpp-module");
    let want = "42 n=7 12 6\n6 hi volt 8\n";
    // Apple's clang++ has no std module (no libc++ modules manifest): on macOS, the clang++ of the
    // LLVM voltc is built with (Homebrew's, whose libc++ has one) builds the program's C++
    let llvm_cxx = cfg!(target_os = "macos").then(|| common::llvm_tool("clang++"));
    // no std module where libclang's clang++ looks (an LLVM built without libc++, as the Intel macOS
    // job's; Windows', whose C++ library is llvm-mingw's, T-0548): skipped, as a missing toolchain is
    let first = e.voltc_cxx(&["check", "cpp_module.volt"], llvm_cxx.as_deref());
    if String::from_utf8_lossy(&first.stderr).contains("finds no modules manifest") {
        eprintln!("skipped cpp_module: {}", String::from_utf8_lossy(&first.stderr).lines().next().unwrap_or(""));
        return;
    }
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc_cxx(&["run", "cpp_module.volt", "--backend", backend], llvm_cxx.as_deref()), "voltc run cpp_module.volt"), want, "C++ modules ({backend})");
    }
    assert_eq!(ok(e.voltc_cxx(&["run", "cpp_module.volt"], Some(llvm_cxx.as_deref().unwrap_or("clang++"))), "voltc run cpp_module.volt (clang++)"), want, "C++ modules built by clang++");
    let src = format!("use {{ \"{}\" }} as gm;\nfn main() -> void {{\n    val x = gm::hidden_helper(1);\n}}\n", Path::new(ROOT).join("tests/interop/geomod.cppm").display().to_string().replace('\\', "/"));
    std::fs::write(e.dir.join("cpp_module_hidden.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_module_hidden.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("unknown name 'hidden_helper'"), "an unexported name: {err}");
    // Ubuntu's libc++.modules.json sits where its relative source path names nothing (GitHub's
    // runner): with a clang++ that finds only a manifest like that, import std; is an error, not a crash
    // (macOS: voltc takes libclang's own clang++, not PATH's)
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        use std::os::unix::fs::PermissionsExt;
        let bin = e.dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(e.dir.join("libc++.modules.json"), r#"{"version":1,"revision":1,"modules":[{"logical-name":"std","source-path":"../share/libc++/v1/std.cppm","is-std-library":true}]}"#).unwrap();
        let path = std::env::var("PATH").unwrap_or_default();
        let wrapper = format!(
            "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in\n  -print-file-name=libstdc++.modules.json) echo libstdc++.modules.json; exit 0;;\n  -print-file-name=libc++.modules.json) echo '{}'; exit 0;;\nesac; done\nPATH='{path}' exec clang++ \"$@\"\n",
            e.path("libc++.modules.json")
        );
        std::fs::write(bin.join("clang++"), wrapper).unwrap();
        std::fs::set_permissions(bin.join("clang++"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let o = Command::new(&e.voltc)
            .args(["check", "cpp_module.volt", "--std"])
            .arg(Path::new(ROOT).join("std"))
            .current_dir(Path::new(ROOT).join("tests/interop"))
            .env("PATH", format!("{}:{path}", bin.display()))
            .env("VOLT_CACHE", e.dir.join("cache"))
            .output()
            .unwrap();
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains("import std; needs") && !err.contains("panic"), "a modules manifest naming a missing source: {err}");
    }
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
    let src = format!("use {{ \"{}\" }} as cpp;\nfn main() -> void {{\n    val x = @cpp<i32>(\"kit::apply_fn<{{&0}}, true>(1)\", 5);\n}}\n", hpp.display().to_string().replace('\\', "/"));
    std::fs::write(e.dir.join("cpp_hole.volt"), src).unwrap();
    let o = e.voltc(&["check", &e.path("cpp_hole.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("{&0} is a function's symbol: pass a function"), "{{&0}} of a number: {err}");
}

/// a class template's specializations (special.hpp): box<i32> is the primary's, laid out by Volt at
/// C++'s size; box<void> (an explicit specialization) and box<i32*> (a partial one's instance) are
/// what clang picks, held by handle with their members worked out per use, in Volt and in a header's
/// signature alike, on both backends; and the primary's fields aren't a specialization's
#[test]
fn cpp_special_class() {
    let e = Env::new("cpp-special-class");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_special_class.volt", "--backend", backend]), "voltc run cpp_special_class.volt"), "4 7 true\n6 3 1.5\n42 42 2\n42 3\n5 1\n34\n", "C++ class specializations ({backend})");
    }
    let hpp = Path::new(ROOT).join("tests/interop/special.hpp").display().to_string().replace('\\', "/");
    std::fs::write(e.dir.join("special_field.volt"), format!("use {{ \"{hpp}\" }} as cpp;\nfn main() -> void {{\n    val s: cpp::sp::box<void> = {{ v: 1, tag: 2 }};\n}}\n")).unwrap();
    let o = e.voltc(&["check", &e.path("special_field.volt")]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("special_field.volt:3") && err.contains("'v'"), "box<void> has none of the primary's fields: {err}");
}

/// function template specializations (special.hpp): C++ picks pick<int> and Meter::unit<double>
/// over their primaries, called per use
#[test]
fn cpp_special_fn() {
    let e = Env::new("cpp-special-fn");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_special_fn.volt", "--backend", backend]), "voltc run cpp_special_fn.volt"), "2 1 2\n25 15\n", "C++ function specializations ({backend})");
    }
}

/// what a library adds to namespace std (special.hpp): its std::hash<Key> keys a
/// std::unordered_map<Key, int>, and its swap runs through argument-dependent lookup
#[test]
fn cpp_special_std() {
    let e = Env::new("cpp-special-std");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_special_std.volt", "--backend", backend]), "voltc run cpp_special_std.volt"), "2 30\n102 101\n", "a library's std additions ({backend})");
    }
}

#[test]
fn cpp_templates() {
    // what Volt's generics can't declare (variadic and non-type templates, auto results, constrained
    // templates, function-like macros, method templates), called per use: clang types each call
    let e = Env::new("cpp-templates");
    let want = "6.5 4\n12\n42 2.5\n3 6\n40\n25 2\n6 18\n9 12\n10 8\n-4 3 -6\n9\n6\n3 7\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_templates.volt", "--backend", backend]), "voltc run cpp_templates.volt"), want, "C++ templates ({backend})");
    }
    // a call C++ rejects is an error at the Volt call, in C++'s words: here the concept
    let hpp = Path::new(ROOT).join("tests/interop/templates.hpp");
    let src = format!("use {{ \"{}\" }} as cpp;\nfn main() -> void {{\n    val x = cpp::tpl::twice(1.5);\n}}\n", hpp.display().to_string().replace('\\', "/"));
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
    let want = "5 42\n0 v98::Shape\n1 2 1 2\ngrid 204\n49 3 2\n4 1 107\n4 11\n5 15 5\n";
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
    // a std::map and std::pair read as tuples under C++98 as under C++11 (no std::tuple_size there),
    // and class template instances' handles and a base's as_ under C++98 (no >> after a template name);
    // a class moved as std::auto_ptr is (T(T&)) passed by value and set into a field under C++98 too
    for std in ["-std=c++98", "-std=c++11"] {
        for backend in ["c", "llvm"] {
            assert_eq!(ok(e.voltc(&["run", "cpp_pairs98.volt", "--cc", std, "--backend", backend]), "voltc run cpp_pairs98.volt"), "map 3 1.75\npair 3 2 42\nbox 5 3 9 7\nnames 2 owner 6 8\n", "pairs under {std} ({backend})");
        }
    }
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
fn cpp_ranges2() {
    // for over C++ ranges whose iterators C++ holds (a shared_ptr in them, move-only, aligned past
    // 8): looped fully and left by break, return and try, each freeing them; std::vector and
    // std::map from a header read under C++98
    let e = Env::new("cpp-ranges2");
    let want = "shared 30 live 0 inside 2\nbreak live 0\nreturn 10 live 0\ntry -1 live 0\nlabeled break live 0\ncontinue 20 live 0\nnested 180 live 0\nmove 10 live 0\nwide 14\nc++98 6 2\nc++98 total 100 50\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_ranges2.volt", "--backend", backend]), "voltc run cpp_ranges2.volt"), want, "C++ ranges C++ holds the iterators of ({backend})");
    }
    // trivially copyable iterators stay in Volt's words; the others go through C++'s heap
    let shown = Command::new(&e.voltc).args(["check", "cpp_ranges2.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    // (the vector as the system's headers spell it: std::vector<int32_t>, libc++'s std::__1::vector<int>)
    let range = |q: &str, rest: &str| src.split("// C++'s ").find(|s| s.lines().next().is_some_and(|l| l.contains(q) && l.contains(rest))).unwrap_or_else(|| panic!("no range for {q}...{rest}: {src}")).to_string();
    let (vector, shared) = (range("vector<", "> looped over"), range("r2::shared_range looped over", ""));
    assert!(vector.contains("volt_range_start") && !vector.contains("volt_range_open"), "std::vector inline: {vector}");
    assert!(shared.contains("volt_range_open") && !shared.contains("volt_range_start"), "shared_ptr range on C++'s heap: {shared}");
    // an over-aligned iterator below C++17
    let o = e.voltc(&["check", "cpp_ranges2_wide14.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("can't loop over C++'s r2::wide_range: its iterators are aligned past 8, which needs C++17 or newer") && err.contains("cpp_ranges2_wide14.volt:7"), "an over-aligned iterator under C++14: {err}");
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
fn cpp_params() {
    // parameters with a Volt form of their own, declared and per use: a reference to an array (const
    // or not, one through an alias with a default), a function pointer, a std::string& (a throw
    // leaves the Volt string as it was, under a callback too), a std::function over a class held by
    // handle, one laid out and one move-only; a C++ std::function Volt keeps, called with a
    // std::string&; parameters written as arrays (T a[N], const T a[], one with a default) a Volt T*;
    // a Volt std::string for a template parameter S (S&, const S&, S, S&&) a C++ std::string, a
    // throw through the plain form a stop; a class template's T& and const T& a Volt reference
    // (laid out and held by handle), C++'s write seen
    let e = Env::new("cpp-params");
    let want = "sum 6\nfill 4 4 4\ntotal 12\ntwice 8 24\nfirst 7 8\napply 5 6 10\n@cpp 42\nshout hi!!\ngrow 2: 7 hi!!~++\ngrow -1: INVALID_ARGUMENT hi!!~++\n@cpp hi!!~++!\nrelay INVALID_ARGUMENT hi!!~++!\nshapes 2 7\npoints 202 45\nspend 15\nasked why??\ncounted 3 7 ab+\narrays 7 4 7 9 4\n@cpp 8 5 1\nalias 8 cells 14\nwrap hey! 4 6\ngauge 40 70 hey!\ntake 5 xyz\ntook 4\nlend 1 1 1 1\nlend moved 2 2\npad 6 hey!##\ntgrow 1: 8 hey!##~+\ntgrow -1: INVALID_ARGUMENT hey!##~+\nwhich 1 2 2 1 2 ab&& cd\nfwd 6 ab&& len 2 4\nnested [[1,2],[3],[]] [[1,2],[3]] [[[1,2],[3],[]],[],[[1,2]]] []\nnested per use [[1,2],[3],[]] 15\nnested [[3],[]] 4.75 hi//you\nmap {1:10,2:20,3:30} {} {4:125,5:50} 140 3 3\nmap {a:1,b:2} {:'',k:'v w'} {1:[],2:[4,5]}\nmap {1:10,2:20,3:30} {1:[],2:[4,5]} 2 2 2\nmap 1 {7:7} 1\npick 2: 20\npick 9: OUT_OF_RANGE\nderef 5 5 3 3 7 7\nsum_ptr 7 size 4 4 8 which 1 2\nchecked 5: 5\nchecked -1: INVALID_ARGUMENT\ntwice 42 tally 4 7 10 10\nkeep 8 11 12\nduo 4.75 which 2 1\nconst pick 2 2 1 1\nstrings 2 3 xab\nmember xyz\nchain abc b\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_params.volt", "--backend", backend]), "voltc run cpp_params.volt"), want, "C++ parameters ({backend})");
        let o = e.voltc(&["run", "cpp_params_gthrow.volt", "--backend", backend]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(o.status.code() == Some(101) && err.contains("C++ exception") && err.contains("negative") && o.stdout.is_empty(), "a template's throw through the plain form ({backend}): {err}");
        // @cpp<cpp_error!R> and the try_ forms of calls worked out per use catch as declared try_ forms do
        // (a fn C++ calls through a pointer: its plain throw is the outer call's, kept past a
        // catching call of its own, which reports its own)
        let caught = "nested ok: INVALID_ARGUMENT negative\ninner: LENGTH_ERROR\nnested fail: INVALID_ARGUMENT negative\ninner only: 96\nbump\nbumped: INVALID_ARGUMENT negative\nbump\ntbumped: INVALID_ARGUMENT negative\nb b\nnonneg 4: 4\nnonneg -4: INVALID_ARGUMENT negative\nboom 1: done\nboom 2: LENGTH_ERROR too many\nthrow 42: UNKNOWN an exception that isn't a std::exception\nbad_alloc: BAD_ALLOC std::bad_alloc\ngrow 2: 5 hi~++\ngrow -1: INVALID_ARGUMENT hi~++\nrelay 99\nnonneg -5: INVALID_ARGUMENT negative\napply 41: 42\napply -5: INVALID_ARGUMENT negative\napply nested: INVALID_ARGUMENT negative\nref -2: INVALID_ARGUMENT negative\nslice 0: 3\nslice 1: INVALID_ARGUMENT negative\nplain 3 42 5 3\nfns 7 7 7 6 6\nfns caught: 6\nfmt 3\ntext 33 op 4\nnames 3 -1 len 5\n";
        assert_eq!(ok(e.voltc(&["run", "cpp_params_catch.volt", "--backend", backend]), "voltc run cpp_params_catch.volt"), caught, "@cpp<cpp_error!R> ({backend})");
        let tried = "checked 2 3: 5\nchecked 2 -5: INVALID_ARGUMENT negative sum\nstretch 2: 5 hi~++\nstretch -1: OUT_OF_RANGE hi~++\nboom 2: LENGTH_ERROR\ntwin 5 -5\nsole 2 -5 read 3 -4\nlone 3 -6\npick -1: INVALID_ARGUMENT negative pick\npick 4: 4\npick 1 -5: RANGE_ERROR negative picks\npick 1 2: 3\nkeep 3: 3\nkeep -2: DOMAIN_ERROR\nmade 1: 1 ab~\nmade -1: DOMAIN_ERROR ab~\ngrow 2: 6 ab~~++\ngrow -1: OUT_OF_RANGE ab~~++\ntake -1: OUT_OF_RANGE 5\n";
        assert_eq!(ok(e.voltc(&["run", "cpp_params_try.volt", "--backend", backend]), "voltc run cpp_params_try.volt"), tried, "try_ forms per use ({backend})");
        // its arguments are worked out before catch mode: a throw in one stops the program, and an
        // early exit in one leaves catch mode off (a later plain throw stops it)
        for file in ["cpp_params_catch_stop.volt", "cpp_params_catch_exit.volt"] {
            let o = e.voltc(&["run", file, "--backend", backend]);
            let err = String::from_utf8_lossy(&o.stderr);
            assert!(o.status.code() == Some(101) && err.contains("C++ exception") && err.contains("negative") && o.stdout.is_empty(), "{file} ({backend}): {err}");
        }
    }
    // parameters written as arrays are declared as pointers (through an alias, of chars, of pointers,
    // of a laid-out struct), not left to per use; an array of arrays is
    let shown = Command::new(&e.voltc).args(["check", "cpp_params.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    // a Volt reference per use: read as an int& first, as its address only when that's no call
    for call in ["pr::rp::deref(int32_t *) -> int", "pr::rp::sum_ptr(int32_t *, int32_t) -> int", "pr::rp::which(int32_t &) -> int", "pr::rp::checked(int32_t *) -> int"] {
        assert!(src.contains(&format!("// C++: {call}, as clang resolves it")), "{call}: {src}");
    }
    // a function template's S& and const S& a Volt S& (S what the reference names), S and S&& a
    // value (S&&'s a var, which C++ moves from); S* stays a pointer; beside an S& or const S&
    // overload, the S or S&& one has a suffixed name (both would take a Volt reference)
    for decl in ["fn wrap(s: S&) -> void", "fn len(s: S&) -> u64", "fn gauge(s: S&) -> i32", "fn pad(s: S&, n: T) -> i32", "fn grow(s: S&, n: i32) -> i32", "fn which(s: S&) -> i32", "fn size_of(a0: S&) -> i32", "fn bump(s: S) -> i32", "fn take(var s: S) -> i32", "fn fwd(var s: S) -> i32", "fn size_by(a0: S) -> i32", "fn deref(p: S*) -> i32", "fn lend(a0: S&) -> i32", "fn give(a0: S&) -> i32", "fn lend_rref(var a0: S) -> i32", "fn give_rref(var a0: S) -> i32", "fn which_const_ref(a0: S&) -> i32"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    // the overload aliases are named by their parameters' forms, not clang's type-parameter-0-0
    assert!(!src.contains("type_parameter"), "an alias named from clang's spelling: {src}");
    // a class template's T& (a generic struct's member) a Volt T&, as a function template's is; its
    // const T& a value (a constructor's too)
    for decl in ["attach fn bump(this: keep<T>&, x: T&) -> void", "attach fn peek(this: keep<T>&, x: T) -> T", "attach fn new(static this: duo<T>, x: T, y: T) -> duo<T>", "attach fn sum(this: duo<T>&, k: T) -> T"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    for call in ["pr::gs::wrap<std::string>(std::string &) -> void", "pr::gs::take<std::string>(VOLT_MOVE(std::string &)) -> int"] {
        assert!(src.contains(&format!("// C++: {call}, as clang resolves it")), "{call}: {src}");
    }
    for decl in ["fn sum3(a: i32*) -> i32", "fn total(a: i32*, n: i32) -> i32", "fn tail(a: i32*) -> i32", "fn tail() -> i32", "fn sum_alias(a: i32*) -> i32", "fn first_char(s: cstr?) -> i32", "fn byte0(buf: u8*) -> i32", "fn argc_of(argv: cstr?*) -> i32", "fn cells(a: pr::ap::cell*, n: i32) -> i32", "fn grid() -> void {}"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    // nested std::vectors by value or const& are nested slices (of bools too); a mutable one and one
    // of a class held by handle stay per use, each stub's comment saying why
    for decl in ["fn shape(v: i32[..][..])", "fn shape_ref(v: i32[..][..])", "fn shape3(v: i32[..][..][..])", "fn shape_rv(v: i32[..][..])", "fn weigh(v: f64[..][..])", "fn spell(v: i8[..][..])","fn widen() -> void {}", "fn flags(v: bool[..][..])", "fn boxes() -> void {}"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    for why in ["std::vector<std::vector<int>> & v) (worked out per use: std::vector<std::vector<int>> & has no Volt form)", "(worked out per use: const std::vector<std::vector<Shape>> & has no Volt form)", "(worked out per use: const std::vector<S> & depends on the template's parameters)"] {
        assert!(src.contains(why), "{why}: {src}");
    }
    // std::map / std::unordered_map by value, const& or && (an alias too) take a Volt std::map&,
    // beside the handle form: stdcxx's, or (no stdcxx form: a std::string key, std::vector<bool>
    // values) a handle of the instance's own; a mutable one too, C++'s entries copied back
    for decl in ["fn dump(m: std::map<i32, i32>&)", "fn dump(m: stdcxx::map<i32, i32>&)", "fn try_dump(m: std::map<i32, i32>&)", "fn dump_u(m: std::map<i32, f64>&)", "fn dump_u(m: stdcxx::unordered_map<i32, f64>)", "fn dump_s(m: std::map<std::string, i32>&)", "fn dump_ss(m: std::map<std::string, std::string>&)", "fn dump_v(m: std::map<i32, std::vec<i32>>&)", "fn dump_rv(m: std::map<i32, i32>&)", "fn dump_a(m: std::map<i32, i32>&)", "fn put_in(m: stdcxx::map<i32, i32>&)", "fn put_s(m: map_", "fn bits(m: map_", "fn dump_s(m: map_"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    assert!(src.contains("fn put_in(m: std::map<i32, i32>&)") && src.contains("fn put_s(m: std::map<std::string, i32>&)"), "a mutable map& has a Volt map form beside its handle: {src}");
    // const& beside &&: the twin pass's second one an alias; a result pointing into the map's copy
    // (a pointer, a view) isn't declared with a Volt std::map& (a copied-out vector is)
    for decl in ["fn both(a0: std::map<i32, i32>&) -> i32", "fn both(a0: stdcxx::map<i32, i32>) -> i32", "fn both_std_map_int_int_rref(a0: std::map<i32, i32>&) -> i32", "fn find(m: stdcxx::map<i32, i32>&, k: i32) -> i32*", "fn row0(m: std::map<i32, std::vec<i32>>&)"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    assert!(!src.contains("fn find(m: std::map<") && !src.contains("fn key0(m: std::map<") && src.contains("fn key0(m: map_"), "results into the map's copy (a handle's view points into C++'s own map): {src}");
    // a variadic function pointer with no fixed parameter has no Volt form (C before C23 has none)
    assert!(src.contains("(worked out per use: int (*)(...) has no Volt form)") && !src.contains("fn(...)"), "R(*)(...): {src}");
    // a per-use name's try_ stub beside its own, unless the header declares that name (then a
    // left-out comment)
    assert!(src.contains("@attributes([@cpp_call(\"try:pr::pu::checked\")])") && src.contains("fn try_checked() -> void {}"), "a per-use try_ stub: {src}");
    assert!(src.contains("// left out: try_twin, worked out per use (the header declares try_twin)") && src.matches("fn try_twin(").count() == 1, "a real try_twin keeps its name: {src}");
    // and beside a declared function or method: one try_sole, one try_read, the header's
    assert!(src.matches("fn try_sole(").count() == 1 && src.matches("fn try_read(").count() == 1 && src.matches("fn try_lone(").count() == 1, "a declared try_ name the header has keeps it: {src}");
    // x.try_m(...) with neither try_m nor m on the class: m's error
    let o = e.voltc(&["check", "cpp_params_no_member.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("no member named 'nothing'") && err.contains("cpp_params_no_member.volt:5"), "neither m nor try_m: {err}");
    // a std::map with no stdcxx form (a std::string key) that C++ made goes back to C++ by its handle,
    // and a Volt std::map to the same function as a copy, under C++17 and C++11
    for std in ["-std=c++17", "-std=c++11"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_map_back.volt", "--cc", std]), "voltc run cpp_map_back.volt"), "total 3 5\n", "cpp_map_back under {std}");
    }
}

#[test]
fn cpp_peruse_errors() {
    // a per-use call C++ can't make: clang's error, at the call, without the probe declaration's own
    // follow-on ('a type specifier is required for all declarations')
    let e = Env::new("cpp-peruse-errors");
    let o = e.voltc(&["check", "cpp_params_bad_call.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("invalid operands") && err.contains("cpp_params_bad_call.volt:6") && !err.contains("type specifier"), "a per-use call's errors: {err}");
}

#[test]
fn cpp_peruse2() {
    // Volt types C++ has no type for (a Volt struct, i32?, an enum with payloads, a tuple, f16, f128:
    // a mirror of their bytes; a closure and a fn value: a std::function) through C++ templates and
    // back unchanged; a function pointer result as a Volt fn, an array reference result as a T[N]&
    let e = Env::new("cpp-peruse2");
    let want = "struct 3 2.5\nopt 7 null\nenum 1.25\ntuple (4, 0.5)\nclosure 40 21\nowned 23 23 46\nfloat true 1.5\ncount 5\ntry 2 2.5\nfnptr 5 10\narray 50 6\nsame 70\nref 41 2.5 5 3 4\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_peruse2.volt", "--backend", backend]), "voltc run cpp_peruse2.volt"), want, "per-use calls with every Volt type ({backend})");
    }
}

#[test]
fn cpp_peruse_layout() {
    // mirrors of Volt types holding i64 and f64 (an @align(16) struct, an array member, a tuple holding
    // an extern "C" fn, whose name has quotes) check their size and alignment against the target's C
    // layout of the type (a static_assert in the C++ unit; under C++98 an array of -1 chars): they
    // pass here, and on i386 (c++ -m32), where C aligns i64 and f64 to 4, the C++ step fails at the
    // mirror instead of a run copying the wrong bytes
    let e = Env::new("cpp-peruse-layout");
    let want = "point 3 2.5\nspan 7 1099511627776 (-2, 0.25)\nshape 2.5\nopt 1.5\nwide 9 16\ntrio 2.5 2.5 2.5 5\nfnptr 5 6\nnums true true 1.5 2.25 4 11\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_peruse_layout.volt", "--backend", backend]), "voltc run cpp_peruse_layout.volt"), want, "mirrors with i64 and f64 ({backend})");
    }
    assert_eq!(ok(e.voltc(&["run", "cpp_peruse_layout.volt", "--cc", "-std=c++98"]), "voltc run cpp_peruse_layout.volt (C++98)"), want, "mirrors' check under C++98");
    let probe = e.path("m32.cpp");
    std::fs::write(&probe, "#include <functional>\n#include <string>\n#include <vector>\n").unwrap();
    // (System V's i386, Linux's: MinGW's aligns i64 and f64 to 8 in a struct, as x86-64 does)
    let m32 = cfg!(target_os = "linux") && Command::new("c++").args(["-m32", "-fsyntax-only", &probe]).output().is_ok_and(|o| o.status.success());
    if !m32 {
        eprintln!("cpp_peruse_layout: no c++ -m32 here, i386's check not run");
        return;
    }
    let o = e.voltc_cxx(&["build", "cpp_peruse_layout.volt", "-o", &e.path("layout32")], Some("c++ -m32"));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("Volt's point: the mirror's size or alignment isn't the type's C layout on this target"), "i386's 4-aligned f64: {err}");
    assert!(err.contains("Volt's (extern \"C\" fn(i32) -> i32, i64): the mirror's size"), "i386's 4-aligned i64, the type's name quoted: {err}");
}

#[test]
fn cpp_array_ref_enum() {
    // a C++ enum's T(&)[N], an enum class : uint8_t's too: the Volt enum array's address, C++'s
    // writes seen in it
    let e = Env::new("cpp-array-ref-enum");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_array_ref_enum.volt", "--backend", backend]), "voltc run cpp_array_ref_enum.volt"), "rotate 1 2 0\nsum 8\nraise 100 7 107\n", "enum arrays ({backend})");
    }
}

#[test]
fn cpp_enum_unsigned() {
    // an unsigned-backed enum's values past its width's signed range (200 in a uint8_t enum, 2^64 - 1
    // in an unsigned long long one) are read unsigned: as enumerators, through C++, as constants
    let e = Env::new("cpp-enum-unsigned");
    let want = "values 200 18446744073709551615\nup 200 200\nflip 18446744073709551615 1\nconsts 200 18446744073709551615\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_enum_unsigned.volt", "--backend", backend]), "voltc run cpp_enum_unsigned.volt"), want, "unsigned enums ({backend})");
    }
}

#[test]
fn cpp_template_conv() {
    // a class template's operator T() is to_T() and its explicit operator bool() to_bool(), on
    // Box<int> and Box<double> alike
    let e = Env::new("cpp-template-conv");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_template_conv.volt", "--backend", backend]), "voltc run cpp_template_conv.volt"), "int 7 true false\ndouble 2.5 true\n", "template conversions ({backend})");
    }
}

#[test]
fn cpp_string_twice() {
    // one Volt string given to two std::string& parameters is one C++ string (both writes land, in
    // C++'s order, copied back once); two strings each get their own
    let e = Env::new("cpp-string-twice");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_string_twice.volt", "--backend", backend]), "voltc run cpp_string_twice.volt"), "sxy ax by\nt13 u2 13\n", "one string twice ({backend})");
    }
}

#[test]
fn cpp_array_ref_handle() {
    // a T(&)[N] of a class Volt holds by handle: a C++ array copied from the handles' objects, and
    // back into them once the call returns (not when it threw); const, one copied but not assigned
    let e = Env::new("cpp-array-ref-handle");
    let want = "total 3\ngrow a+ 11 b+ 12\ntotal 23\nthrew INVALID_ARGUMENT negative\nkept a+ 11 b+ 12\ntried a++ 12 b++ 13\npins 7\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_array_ref_handle.volt", "--backend", backend]), "voltc run cpp_array_ref_handle.volt"), want, "handle arrays ({backend})");
    }
    // a class that can't be copied in (or, for a T(&)[N], assigned back) has no Volt form for it
    let shown = Command::new(&e.voltc).args(["check", "cpp_array_ref_handle.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("fn pin_sum(p: ar::Pin[2]&) -> i32") && src.contains("fn total(w: ar::Widget[2]&) -> i32") && src.contains("fn grow(w: ar::Widget[2]&, by: i32) -> void"), "copyable handle classes' arrays: {src}");
    for (f, t) in [("void ar::pin_touch", "Pin (&)[2] p"), ("int ar::lock_sum", "const Lock (&)[2] l"), ("void ar::lock_touch", "Lock (&)[2] l")] {
        let ty = &t[..t.len() - 2];
        assert!(src.contains(&format!("// C++: {f}({t}) (worked out per use: {ty} has no Volt form)")), "{f}: {src}");
    }
    // under C++98 too, where std::vector's push_back may assign: a const one of a class that's
    // copied but not assigned has no Volt form there, and has one from C++11 on
    for std in ["-std=c++98", "-std=c++17"] {
        for backend in ["c", "llvm"] {
            assert_eq!(ok(e.voltc(&["run", "cpp_array_ref98.volt", "--backend", backend, "--cc", std]), "voltc run cpp_array_ref98.volt"), "total 3\ngrow 11 23\nstrings abx cx 5\n", "handle and string arrays ({std}, {backend})");
        }
        let shown = Command::new(&e.voltc).args(["check", "cpp_array_ref98.volt", "--cc", std, "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
        let src = String::from_utf8_lossy(&shown.stderr);
        let left = src.contains("// C++: int ar98::pin_sum(const Pin (&)[2] p) (worked out per use: const Pin (&)[2] has no Volt form)");
        assert!(src.contains("fn total(b: ar98::Box[2]&) -> i32") && left == (std == "-std=c++98") && (left || src.contains("fn pin_sum(p: ar98::Pin[2]&) -> i32")), "{std}: {src}");
    }
}

#[test]
fn cpp_array_ref2() {
    // a const std::string_view(&)[N] parameter takes a Volt str[N]; a T(&)[N] result of an enum is a
    // Volt T[N]& into C++'s array, of a class held by handle a T[N] of handles borrowing its elements
    let e = Env::new("cpp-array-ref2");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_array_ref2.volt", "--backend", backend]), "voltc run cpp_array_ref2.volt"), "views 5 abc+de\nmodes 2 1 2\nwidgets 1 20 20\n", "string views and array results ({backend})");
    }
}

#[test]
fn cpp_value_params() {
    // class templates over an enum or a char value are Volt generics over the enum's integer type
    // (C++ getting static_cast<E>(n)) or char's, laid out or held by handle, under C++98 too
    let e = Env::new("cpp-value-params");
    let want = "tag 10 20\nchar 65 98\nscale 4.5\nnamed 8\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_value_params.volt", "--backend", backend]), "voltc run cpp_value_params.volt"), want, "enum and char value parameters ({backend})");
    }
    assert_eq!(ok(e.voltc(&["run", "cpp_value_params.volt", "--cc", "-std=c++98"]), "voltc run cpp_value_params.volt (C++98)"), want, "enum and char value parameters under C++98");
}

#[test]
fn cpp_fn_kept() {
    // a closure given to a std::function parameter taken by value moves in: C++ keeps and calls it
    // after the scope that made it is gone, and its captures are deleted with the last copy (leak
    // checked); a plain fn and a fn value are lent
    let e = Env::new("cpp-fn-kept");
    let want = "click 10\nclick 16\ncleared -1\nscope done\ndropped 7\nkept 22\nplain 10\nvalue 12\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_fn_kept.volt", "--backend", backend, "--leak-check"]), "voltc run cpp_fn_kept.volt"), want, "a kept closure ({backend})");
    }
}

#[test]
fn cpp_fn_refs() {
    // a closure for a std::function taking a std::string& (its changes go back), a non-const T& of a
    // number or of a class Volt lays out, a class held by handle by & or const&, a T&&, or giving
    // back a class held by handle (made in C++'s storage)
    let e = Env::new("cpp-fn-refs");
    let want = "shout hi!\nmeasure 10\nmade tri:16\ntwice 25\nrenamed b\nmoved 72\ntaken 4\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_fn_refs.volt", "--backend", backend]), "voltc run cpp_fn_refs.volt"), want, "std::functions over references and handle classes ({backend})");
    }
}

#[test]
fn cpp_maps_more() {
    // a Volt std::map for a std::map with another order (std::greater, a comparator class), a
    // mutable map& and unordered_map& (C++'s inserts, changes and erases come back), enum keys and
    // values, values of a class Volt lays out
    let e = Env::new("cpp-maps-more");
    let want = "first_desc 5\nshortest a\nbump 3 12 11 11\ndrop_odd false 1\nreds 4\npaint true\nxsum 7\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_maps_more.volt", "--backend", backend]), "voltc run cpp_maps_more.volt"), want, "map parameters ({backend})");
    }
}

#[test]
fn cpp_copy_rebase() {
    // a string_view, a pointer or a reference result into the copy made for a const std::string& (of
    // a str) or a const std::vector<T>& (of a slice): the same place in the Volt memory
    let e = Env::new("cpp-copy-rebase");
    let want = "trim [hello] at 2\nbiggest 9 at 1\nleftmost 2 7 at 1\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_copy_rebase.volt", "--backend", backend]), "voltc run cpp_copy_rebase.volt"), want, "results into a parameter's copy ({backend})");
    }
}

#[test]
fn cpp_fn_handles() {
    // a named Volt fn for a function pointer taking a class Volt holds by handle (by const&, & or
    // &&) or a std::string&: C++ calls a thunk made for that fn, kept or called at once; a fn value
    // in a variable has no symbol for one: an error naming the parameter
    let e = Env::new("cpp-fn-handles");
    let want = "apply 3 13\nmoved 5\nrename bb\nshouted hi!\ncounted 5\nkept 14\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_fn_handles.volt", "--backend", backend]), "voltc run cpp_fn_handles.volt"), want, "function pointers over handle classes ({backend})");
    }
    let o = e.voltc(&["check", "cpp_fn_handles_var.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("the argument for comptime parameter 'f' must be known at compile time"), "a fn value in a variable: {err}");
}

#[test]
fn cpp_fnptr_types() {
    // function pointer parameters whose signature has a class Volt lays out (by reference), an enum
    // or a reference to a number take a named Volt fn: declared ones as a Volt extern "C" fn of that
    // signature, per-use ones (templates) through volt_fn_as, a deduced F calling it
    let e = Env::new("cpp-fnptr-types");
    let want = "each 10\nmode 2\nsmall 90\nnext 1\ngrow 3\nbump 5\nbigger 2\nscale 2\ntwice 6\nsmall_t 13\nwith_ref 5\npicked 3\nmode seen 1\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_fnptr_types.volt", "--backend", backend]), "voltc run cpp_fnptr_types.volt"), want, "function pointers with classes, enums and references ({backend})");
    }
}

#[test]
fn cpp_assign98() {
    // under C++98 a class with a const or reference member (or a member or base with one) declares an
    // assignment it can't define: no set_ for such a field and no Volt form for such a mutable T(&)[N],
    // as from C++11 on; a class with its own assignment keeps its setter
    let e = Env::new("cpp-assign98");
    for std in ["-std=c++98", "-std=c++17"] {
        for backend in ["c", "llvm"] {
            assert_eq!(ok(e.voltc(&["run", "cpp_assign98.volt", "--backend", backend, "--cc", std]), "voltc run cpp_assign98.volt"), "bag 5 1\nref 7\n", "{std}, {backend}");
        }
        let shown = Command::new(&e.voltc).args(["check", "cpp_assign98.volt", "--cc", std, "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
        let src = String::from_utf8_lossy(&shown.stderr);
        assert!(!src.contains("fn set_p(") && !src.contains("fn set_d(") && src.contains("// C++: void as98::pin_touch(Pin (&)[2] p) (worked out per use: Pin (&)[2] has no Volt form)"), "{std}: {src}");
        assert!(src.contains("fn set_o(this: Bag&") && src.contains("fn set_n(this: Bag&") && src.contains("fn set_tag(this: Pin&"), "{std}: {src}");
    }
}

#[test]
fn cpp_array_ref_string() {
    // a std::string(&)[N]: a Volt std::string[N]&, C++'s changes copied back once the call returns
    // (not when it threw); a const one a str[N]
    let e = Env::new("cpp-array-ref-string");
    let want = "append abxy cxy\nthrew INVALID_ARGUMENT negative\nkept abxy cxy\ntried abxy! cxy!\nlengths 8\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_array_ref_string.volt", "--backend", backend]), "voltc run cpp_array_ref_string.volt"), want, "string arrays ({backend})");
    }
    // N is the Volt array type's: another length is a type error
    let o = e.voltc(&["check", "cpp_array_ref_size.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("argument 1 is a std::string[3]&, but 'append' wants a std::string[2]&"), "another length: {err}");
}

#[test]
fn cpp_clang_root() {
    // a clang-typed @cpp with no C++ import leaves this file's own generics Volt's: a reference
    // deduced as one (it writes through), a plain fn's name a fn value
    let e = Env::new("cpp-clang-root");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_clang_root.volt", "--backend", backend]), "voltc run cpp_clang_root.volt"), "root 2 9 fn(i32) -> i32\n", "Volt generics beside a clang-typed @cpp ({backend})");
    }
    // ...nor its own cpp_error a C++ import's, nor its generic lent a val's std::string a C++
    // template's (no second error, in the generic's body)
    let o = e.voltc(&["check", "cpp_clang_root_errors.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("E is a C++ import's cpp_error, not cpp_error") && err.contains("'s' is a val, and grow changes it") && !err.contains("parameter without var"), "a clang-typed @cpp's file is no C++ import: {err}");
    // per-use @cpps in a nested namespace declared before two imports, needing the second's headers
    // (imports are all declared before any body is checked, so no implicit context comes first)
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_clang_root_later.volt", "--backend", backend]), "voltc run cpp_clang_root_later.volt"), "later 57\n", "a per-use @cpp needing a later import's headers ({backend})");
    }
    // ...where no import makes it: the error of the one that has the name, else the first's
    let o = e.voltc(&["check", "cpp_clang_root_later_errors.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("no matching function for call to 'grow'") && !err.contains("undeclared identifier 'pr'") && err.contains("undeclared identifier 'nowhere'"), "a per-use @cpp no import makes: {err}");
    // ...and one with no import at all
    assert_eq!(ok(e.voltc(&["run", "cpp_clang_root_text.volt"]), "voltc run cpp_clang_root_text.volt"), "text 4\n", "@cpp<R, std::string> with no C++ import");
}

#[test]
fn cpp_peruse3() {
    // an explicit template argument naming a Volt struct, a tuple or an enum with payloads in a call
    // made per use (same<cell>(a, b), size_of<shape>() with nothing to deduce T from): its mirror, as
    // for a deduced one
    let e = Env::new("cpp-peruse3");
    let want = "struct true false\ntuple true false\nsize true true true\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_peruse3.volt", "--backend", backend]), "voltc run cpp_peruse3.volt"), want, "explicit template arguments of Volt types ({backend})");
    }
}

#[test]
fn cpp_peruse5() {
    // calls made per use taking T(&)[N] of an imported enum (the probe names the enum) or of a class
    // held by handle (its objects copied in and back), nested bool slices, a slice of handles (their
    // objects copied into the std::vector), T(&)[M][N] (a Volt T[N][M]), a pointer to a Volt struct's
    // mirrors, and giving back a std::vector of a class held by handle (owning handles), with a class
    // held by handle as an explicit template argument (T-0686)
    let e = Env::new("cpp-peruse5");
    let want = "modes 12 2\nwidgets xy z\nbits 3\nnames xz\ngrid 21 9\nlast 3 4\nmade 2 ab\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_peruse5.volt", "--backend", backend]), "voltc run cpp_peruse5.volt"), want, "per-use arrays and vectors ({backend})");
    }
}

#[test]
fn cpp_peruse4() {
    // a call made per use whose result is a mirror (a Volt struct, a tuple, an enum with payloads),
    // deduced, with the template argument given, named only in the result (zero<point>(), its try_
    // form), other than the parameter's (conv<point, shape>(p)) or pointed to: that Volt value back;
    // a reference result with nothing to be into (global<point>()), or into the wrapper's own copy of
    // an argument (h.pick(p)): a copy; one into the object (h.at_n(0)): a reference (T-0633)
    let e = Env::new("cpp-peruse4");
    let want = "struct 3 2.5 3 2.5\ntuple (4, 0.5) (4, 0.5)\nenum 1.25 7\nzero 0 0 (0, 0) 0\ntry 0\nconv 0 global 9 0\naddr 6 1.5 true\npick 3 2.5 at_n 8\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_peruse4.volt", "--backend", backend]), "voltc run cpp_peruse4.volt"), want, "mirrored results ({backend})");
    }
}

#[test]
fn cpp_twin_ct() {
    // a class template Volt declares: its method templates (instance, static, deduced and with the
    // template argument given) worked out per use, under C++98 too (T-0640)
    let e = Env::new("cpp-twin-ct");
    let want = "bag 8 9 9 7\nsz 8 2\ntag 11 6\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_twin_ct.volt", "--backend", backend]), "voltc run cpp_twin_ct.volt"), want, "a class template's method templates ({backend})");
    }
    assert_eq!(ok(e.voltc(&["run", "cpp_twin_ct.volt", "--cc", "-std=c++98"]), "voltc run cpp_twin_ct.volt (C++98)"), want, "a class template's method templates under C++98");
}

#[test]
fn cpp_twin() {
    // a template pair f(T&) / f(T) (and const T& / T): with T explicit both overloads take the
    // argument, so each wrapper names its own; f(&m) changes m, f_value(5) a copy; T a pointer, a
    // defaulted trailing argument (given), a class's static methods (a static twin and solo beside the
    // free ones: ns::f is the free one), instance method pairs (const and volatile ones)
    let e = Env::new("cpp-twin");
    let want = "ref 1 6\nvalue 2\npeek 13 24\nderef 36 46\ndflt 50 5 62\nbox 70 12 83\nstatic 3 101 96 91\nacc 100 8 208\nget 309 409\nvol 900 2 1005\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_twin.volt", "--backend", backend]), "voltc run cpp_twin.volt"), want, "a reference / value template pair ({backend})");
    }
    assert_eq!(ok(e.voltc(&["run", "cpp_twin.volt", "--cc", "-std=c++98"]), "voltc run cpp_twin.volt (C++98)"), want, "a reference / value template pair under C++98");
    // the pointer takes every argument: a pair has no forms without its defaulted one
    let shown = Command::new(&e.voltc).args(["check", "cpp_twin.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("fn dflt(x: T&, k: i32) -> i32") && src.contains("fn dflt_value_int(x: T, k: i32) -> i32"), "the full forms: {src}");
    for none in ["fn dflt(x: T&) -> i32", "fn dflt_value_int(x: T) -> i32"] {
        assert!(!src.contains(none), "{none} can't pick its overload: {src}");
    }
}

#[test]
fn cpp_twin_rq() {
    // ref-qualified method template pairs (const &, &&): the member pointer carries the qualifiers
    let e = Env::new("cpp-twin-rq");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_twin_rq.volt", "--backend", backend]), "voltc run cpp_twin_rq.volt"), "cr 709 809\nrr 500 4\nrrv 604\n", "ref-qualified method pairs ({backend})");
    }
}

#[test]
fn cpp_try_inst() {
    // a try_ form that appears only while checking (a class template instance held by handle, its
    // methods worked out per use) in an import with no throwing declared function: cpp_error is there
    let e = Env::new("cpp-try-inst");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_try_inst.volt", "--backend", backend]), "voltc run cpp_try_inst.volt"), "get 7 plain 2\ntry_get RANGE_ERROR neg\n", "a template instance's try_ form ({backend})");
    }
}

#[test]
fn cpp_defaults() {
    // a default argument is a top-level = in the parameter's tokens: an array reference's bound, a
    // std::array's size and a decltype's expression are not one, a template's = is outside the parameter
    let e = Env::new("cpp-defaults");
    let want = "ref 1 2\nalias 8\nexpr 3 5\ndt 10 11\ncmp 1 0\nplain 4\ntp 9\ntail 8\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_defaults.volt", "--backend", backend]), "voltc run cpp_defaults.volt"), want, "C++ default arguments ({backend})");
    }
    let shown = Command::new(&e.voltc).args(["check", "cpp_defaults.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    for none in ["fn ref_plain()", "fn arr()", "fn dt_plain()"] {
        assert!(!src.contains(none), "{none} has no default: {src}");
    }
    assert!(src.contains("fn ref_alias()") && src.contains("fn expr()") && src.contains("fn dt()") && src.contains("fn cmp()"), "the defaulted forms: {src}");
    // each of these has both forms: with its argument and without
    for name in ["g", "h", "p", "a"] {
        assert!(src.contains(&format!("    fn {name}() -> i32")) && src.contains(&format!("    fn {name}(")), "{name} without its default: {src}");
        assert!(src.matches(&format!("    fn {name}(")).count() >= 2, "{name} with and without its argument: {src}");
    }
}

#[test]
fn cpp_params_refused() {
    // what those parameters don't take: another array size, a closure for a function pointer; and a
    // result that would point into a std::string&'s copy, left out of the declarations and an error
    // per use
    let e = Env::new("cpp-params-refused");
    let check = |file: &str| {
        let o = e.voltc(&["check", file]);
        assert!(!o.status.success(), "{file} checks");
        String::from_utf8_lossy(&o.stderr).to_string()
    };
    let err = check("cpp_params_size.volt");
    assert!(err.contains("argument 1 is a i32[4]&, but 'fill' wants a i32[3]&"), "another array size: {err}");
    let err = check("cpp_params_closure.volt");
    assert!(err.contains("argument 1 is a closure(i32) -> i32, but 'apply' wants a extern \"C\" fn(i32) -> i32"), "a closure for a function pointer: {err}");
    // a fn with a reference or a C++ class in its signature, as a function pointer to a call worked
    // out per use (plain, @cpp<R>'s {i} and {&i}, an operator's operand) where it can't cross as its
    // own pointer (a class held by handle, a slice, @cpp's holes, no matching function pointer): an
    // error naming both
    // (one line per diagnostic, its location first: each message is checked at its own line)
    let o = e.voltc(&["check", "cpp_params_fnref.volt", "--message-format", "short"]);
    assert!(!o.status.success(), "cpp_params_fnref.volt checks");
    let err = String::from_utf8_lossy(&o.stderr).to_string();
    for (line, why) in [
        (8, "'by_shape' takes a cpp::pr::Shape&, which has no C function-pointer form"),
        (9, "'by_point' takes a cpp::pr::point, which has no C function-pointer form"),
        (10, "'first' returns a i32&, which has no C function-pointer form"),
        (11, "'first' returns a i32&, which has no C function-pointer form"),
        (12, "'by_ref' takes a i32&, which has no C function-pointer form"),
        (13, "'by_ref' takes a i32&, which has no C function-pointer form"),
    ] {
        assert!(err.lines().any(|l| l.contains(&format!("cpp_params_fnref.volt:{line}:")) && l.contains(why)), "line {line}, {why}: {err}");
    }
    let err = check("cpp_params_view.volt");
    assert!(err.contains("its result would point into a copy (of a string, a vector or a map) that's gone once the call returns") && err.contains("cpp_params_view.volt:7"), "a view into the copy, per use: {err}");
    let shown = Command::new(&e.voltc).args(["check", "cpp_params.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("its result would point into a copy (of a string, a vector or a map) that's gone once the call returns") && !src.contains("fn first_word("), "a view into the copy, declared: {src}");
    assert!(!src.contains("fn first_at(") && !src.contains("fn name_of(") && src.contains("fn count_up("), "structs holding a pointer or a view into the copy, declared: {src}");
    // into a parameter's temporary (a slice's std::vector, a str's std::string): a pointer to an
    // element is moved into the slice (cpp_copy_rebase), a cstr is left out declared (a str has no
    // NUL after it), an error per use; a reference to a number is copied out in the call, so it stays
    for none in ["fn cstr_of("] {
        assert!(!src.contains(none), "{none}: {src}");
    }
    for decl in ["fn sum_of(", "fn twice_of(", "fn len_of(", "fn back_ref(v: i32[..]) -> i32", "fn data_of(v: i32[..]) -> i32*"] {
        assert!(src.contains(decl), "{decl}: {src}");
    }
    let err = check("cpp_params_temp.volt");
    assert!(err.contains("its result would point into a copy (of a string, a vector or a map) that's gone once the call returns") && err.contains("cpp_params_temp.volt:7"), "a pointer into a slice's vector, per use: {err}");
    let err = check("cpp_params_struct_view.volt");
    assert!(err.contains("its result would point into a copy (of a string, a vector or a map) that's gone once the call returns") && err.contains("cpp_params_struct_view.volt:7"), "a struct holding a pointer into the copy, per use: {err}");
    // a Volt std::string for a template parameter nested in another type (S*, std::vector<S>) or
    // the result, each call
    let err = check("cpp_params_gnest.volt");
    let why = "a Volt std::string crosses to C++ only as itself (a template's S, S& or const S&), not inside another type or as a result";
    for line in ["cpp_params_gnest.volt:8", "cpp_params_gnest.volt:9", "cpp_params_gnest.volt:11"] {
        assert!(err.contains(line), "{line}: {err}");
    }
    assert_eq!(err.matches(why).count(), 3, "S nested or the result: {err}");
    // a std::string without & for a template's S& or const S&: an error naming the parameter
    let err = check("cpp_params_gbare.volt");
    for (line, f) in [(7, "wrap"), (11, "len")] {
        assert!(err.contains(&format!("cpp_params_gbare.volt:{line}")) && err.contains(&format!("argument 1 has type std::string, but '{f}' wants a reference (S&) for s: pass one (&arg)")), "{f} without &: {err}");
    }
    // an i32 without & for a class template's T&: an error naming the parameter, as a generic
    // struct's member and as a generic handle's worked out per use (a Volt number is an rvalue there)
    let err = check("cpp_params_tbare.volt");
    assert!(err.contains("cpp_params_tbare.volt:8") && err.contains("argument 1 is a i32, but 'bump' wants a i32&"), "a generic struct's T& without &: {err}");
    assert!(err.contains("cpp_params_tbare.volt:12") && err.contains("non-const lvalue reference to type 'int' cannot bind to a temporary") && err.contains("passing argument to parameter 'x' here"), "a generic handle's T& without &, per use: {err}");
    // C++ writing into a val or a temporary for an S&-only template, through its Volt generic and
    // in @cpp: an error each call
    let err = check("cpp_params_gval.volt");
    assert!(err.contains("'k' is a val, and wrap changes it (through s): declare it with var") && err.contains("cpp_params_gval.volt:7"), "a val through the generic: {err}");
    assert!(err.contains("'k' is a val, and C++ would change it: declare it with var") && err.contains("cpp_params_gval.volt:8"), "a val in @cpp: {err}");
    assert!(err.contains("C++ would change a temporary std::string here (the template takes it as S&)") && err.contains("cpp_params_gval.volt:12"), "a temporary in @cpp: {err}");
    // a parameter with no Volt form: a per-use stub whose comment shows the C++ declaration and
    // names the type; a call with a slice names it too
    assert!(src.contains("// C++: int pr::nv::boxes(const std::vector<std::vector<Shape>> & v) (worked out per use: const std::vector<std::vector<Shape>> & has no Volt form)") && src.contains("fn boxes() -> void {}"), "the stub says why: {src}");
    let err = check("cpp_params_unmapped.volt");
    assert!(err.contains("std::vector<std::vector<Shape>>") && err.contains("cpp_params_unmapped.volt:6"), "a wrong argument per use: {err}");
    // a mutable std::map& with no stdcxx form takes the instance's handle only: a call with a Volt
    // map (which C++ would change a copy of) is refused, naming both types
    // a mutable map takes a Volt map too, C++'s entries copied back (cpp_maps_more)
    assert_eq!(ok(e.voltc(&["run", "cpp_params_map.volt"]), "voltc run cpp_params_map.volt"), "1 7\n", "a mutable map& given a Volt map");
    // Volt references per use, one wanting an int& and another an int*, none fitting: the lvalue reading's error
    let err = check("cpp_params_mixed.volt");
    assert!(err.contains("cannot initialize a parameter of type 'int *' with an lvalue of type 'double'") && err.contains("cpp_params_mixed.volt:8"), "an lvalue and an address in one call: {err}");
}

#[test]
fn cpp_ref_mix() {
    // an int& and an int* parameter in one per-use call take each Volt reference as it wants it;
    // f(T&) beside f(T*) still gets f(&x) as f(T&) (T-0694)
    let e = Env::new("cpp-ref-mix");
    let want = "mix 11 22\nmix 1.5 3.5\nswap 22 11\npick 1 3\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_ref_mix.volt", "--backend", backend]), "voltc run cpp_ref_mix.volt"), want, "int& and int* in one call ({backend})");
    }
}

#[test]
fn cpp_overloads() {
    // overloads Volt can't tell apart (long / long long, char / signed char / unsigned char, a const
    // method and its non-const twin): every one callable, the later ones named for their parameter
    // types and calling exactly their own overload, for free functions, methods and constructors; a
    // real declaration keeps a name an alias would take, and the alias is a left-out comment
    let e = Env::new("cpp-overloads");
    let want = "which 1 2\nletter 1 2 3\nf 4 42 40 42\nh 1 2 2\nnew 5 long 10 long long\nget 5 -5\nadd 6 16\nscaled 6 -6\ncall 4 2 peek 1 2\nopen lref 7 rref 8 8\nopen rref 7\nsize 1 2\npinned 3\npinned 103 141\ncrate 5\ndropped 3\nspend 40\ntaken 1 3\nholder 5 5\nholder 5 6\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_overloads.volt", "--backend", backend]), "voltc run cpp_overloads.volt"), want, "C++ overloads ({backend})");
    }
    let shown = Command::new(&e.voltc).args(["check", "cpp_overloads.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    // (where long is 64 bits: on Windows long and long long don't collide)
    if !cfg!(windows) {
        assert!(src.contains("fn which_long_long_2("), "the alias a real declaration took gets a counter: {src}");
        assert!(src.contains("// C++: int ov::h(long long x, int a, int b)\n    fn h(x: i64, a: i32) -> i32"), "a form after its alias keeps the C++ comment: {src}");
    }
    assert!(!src.contains("// left out: int taken::") && !src.contains("// left out: int again::"), "no overload left out: {src}");
    // an && method of a template's instance, worked out per use, consumes the handle too
    let o = e.voltc(&["check", "cpp_overloads_holder.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("cpp_overloads_holder.volt:8") && err.contains("moved") && !err.contains("ref-qualifier"), "a handle used after an && method per use: {err}");
    // an && method consumes the handle
    let o = e.voltc(&["check", "cpp_overloads_moved.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("cpp_overloads_moved.volt:7") && err.contains("moved"), "a handle used after an && method: {err}");
    // ...on a class that can be neither copied nor moved too; through a borrowed handle (as_Base, a
    // reference result) there's no object to hand C++, so the call stops the program before reading it
    let o = e.voltc(&["check", "cpp_overloads_pinned_moved.volt"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("cpp_overloads_pinned_moved.volt:8") && err.contains("moved"), "a pinned handle used after an && method: {err}");
    for backend in ["c", "llvm"] {
        for (prog, before, says) in [("cpp_overloads_pinned_base.volt", "before 8\n", "can't call ov::Pinned::take (an && method) through a borrowed handle: ov::Pinned can't be copied"), ("cpp_overloads_pinned_ref.volt", "before 41\n", "can't call ov::Pinned::take (an && method) through a borrowed handle: ov::Pinned can't be copied"), ("cpp_overloads_pinned_crate.volt", "before 9\n", "through a borrowed handle: ov::PinnedCrate can't be copied")] {
            let o = e.voltc(&["run", prog, "--backend", backend]);
            let (out, err) = (String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
            assert!(o.status.code() == Some(101) && out == before && err.contains(says), "{prog} ({backend}): {:?} {out} {err}", o.status);
        }
    }
}

#[test]
fn cpp_overload_twice() {
    // overloads whose names collide again after the rename (a real function with the name, a second
    // alias with it, a const twin's name taken) take the first free one: the words, then _2
    // (where long is 64 bits: on Windows long and long long don't collide, so nothing is renamed)
    if cfg!(windows) {
        return;
    }
    let e = Env::new("cpp-overload-twice");
    let want = "f 1 3 2\ng 1 3 2\nd 1 1 3 2 2\nm 1 2 3\npeek 4 6 5\n";
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_overload_twice.volt", "--backend", backend]), "voltc run cpp_overload_twice.volt"), want, "overloads colliding twice ({backend})");
    }
    let shown = Command::new(&e.voltc).args(["check", "cpp_overload_twice.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(!src.contains("// left out: int tw::") && !src.contains("// left out: int tw::Twice"), "no overload left out: {src}");
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

#[test]
fn cpp_leftout() {
    // classes once left out: an over-aligned one held by handle (C++'s aligned new and delete), a
    // class template with a std::mutex field as a generic handle, a class with a protected
    // destructor used through its factory's borrowed handle and freed by its own destroy
    let e = Env::new("cpp-leftout");
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_leftout.volt", "--backend", backend]), "voltc run cpp_leftout.volt"), "vec8 36 7 true true\nempty 28\nguarded 42 41\nsession 42 21\ndeleted 1\n", "left-out C++ classes ({backend})");
    }
    let shown = Command::new(&e.voltc).args(["check", "cpp_leftout.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!(src.contains("@cpp_handle(\"lo::vec8\")") && src.contains("@cpp_handle(\"lo::guarded\")") && !src.contains("a field's type isn't one Volt can use") && !src.contains("attach fn delete(this: session&"), "vec8 and guarded handles (no partial struct), session never deleted by Volt: {src}");
    // below C++17 there's no aligned new: left out, saying so
    let shown = Command::new(&e.voltc).args(["check", "cpp_leftout14.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let err = String::from_utf8_lossy(&shown.stderr);
    assert!(!shown.status.success() && err.contains("left out: class lo::vec8") && err.contains("needs C++17"), "an over-aligned class under C++14: {err}");
}

#[test]
fn cpp_aligned_field() {
    // a class whose field is an aligned typedef's (aligned past its int, or below it) isn't laid out
    // as Volt lays out the int: held by handle, not a struct with Volt's alignment or offsets
    let e = Env::new("cpp-aligned-field");
    // (Windows: MinGW's MSVC layout doesn't lower a field's alignment by a typedef, so tight and
    // mixed are laid out as Volt lays them out, value structs: tight is 8 bytes there)
    let tight = if cfg!(windows) { "tight 9 8" } else { "tight 9 6" };
    for backend in ["c", "llvm"] {
        assert_eq!(ok(e.voltc(&["run", "cpp_aligned_field.volt", "--backend", backend]), "voltc run cpp_aligned_field.volt"), format!("cell 7 7 true true 32\n{tight}\nmixed 11 0.5\nsqueezed 13 5\ntemplates 5 34 35 9\nbox 4 4 4 64\n"), "aligned-typedef and packed fields ({backend})");
    }
    let shown = Command::new(&e.voltc).args(["check", "cpp_aligned_field.volt", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    let handles: &[&str] = if cfg!(windows) { &["cell", "squeezed"] } else { &["cell", "tight", "mixed", "squeezed"] };
    for c in handles {
        assert!(src.contains(&format!("@cpp_handle(\"af::{c}\")")), "af::{c} held by handle: {src}");
    }
    // below C++17 the ones aligned to 8 or less are still handles (plain new); cell (16) is left out,
    // and cell_x, which takes one, is only worked out per use: the rest of the header imports (T-0634)
    assert_eq!(ok(e.voltc(&["run", "cpp_aligned_field14.volt", "--cc", "-std=c++14"]), "voltc run cpp_aligned_field14.volt"), "c++14 9 11\npacked 9\n", "handles under C++14");
    let shown = Command::new(&e.voltc).args(["check", "cpp_aligned_field14.volt", "--cc", "-std=c++14", "--std"]).arg(Path::new(ROOT).join("std")).current_dir(Path::new(ROOT).join("tests/interop")).env("VOLT_SHOW_CPP", "1").output().unwrap();
    let src = String::from_utf8_lossy(&shown.stderr);
    assert!((cfg!(windows) || (src.contains("@cpp_handle(\"af::tight\")") && src.contains("@cpp_handle(\"af::mixed\")"))) && src.contains("left out: class af::cell") && src.contains("needs C++17") && src.contains("af::cell_x(const cell & v) (worked out per use"), "C++14: tight and mixed handles, cell left out, cell_x per use: {src}");
    // and the class templates aligned by alignas or an aligned typedef are left out too; the packed
    // one, aligned to 1, is still a handle (T-0638)
    // (tholder, holding a twide, with it)
    for t in ["tcell", "twide", "tslot", "tholder"] {
        assert!(src.contains(&format!("left out: class template af::{t} ")) && !src.contains(&format!("@cpp_handle(\"af::{t}\")")), "C++14: af::{t} left out: {src}");
    }
    assert!(src.contains("@cpp_handle(\"af::tpacked\")"), "C++14: af::tpacked a handle: {src}");
    // an instance of a template handle on a 32-aligned class (tbox<v32>): below C++17 plain new
    // doesn't align it, so it doesn't build (T-0645)
    // (and as a function's result, and a class held by handle aligned to 32: nbig)
    for f in ["cpp_aligned_field14_new.volt", "cpp_aligned_field14_result.volt", "cpp_aligned_field14_class.volt"] {
        let o = e.voltc(&["run", f, "--cc", "-std=c++14"]);
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains("volt_cpp_needs_cxx17_aligned_new"), "C++14: {f} made by plain new: {err}");
    }
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
        ("glm/glm.hpp", "libs/glm.volt", &[][..], "2.5 3 1\nlength 3\n"),
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
            // its stderr's end first: a compiler's warnings come before the error that stopped it
            let err = String::from_utf8_lossy(&o.stderr);
            let tail: String = err.chars().rev().take(700).collect::<Vec<_>>().into_iter().rev().collect();
            assert!(o.status.success(), "{name}: run.sh failed ({}): ...{tail}\n--- stdout\n{}", o.status, String::from_utf8_lossy(&o.stdout));
            // (a C program's text-mode stdout ends its lines with \r\n on Windows)
            let want = std::fs::read_to_string(ex.join("expected.txt")).unwrap().replace("\r\n", "\n");
            assert_eq!(String::from_utf8_lossy(&o.stdout).replace("\r\n", "\n"), want, "{name} prints something else");
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
/// the linker flag dropping libraries nothing uses (macOS's linker calls it -dead_strip_dylibs)
const AS_NEEDED: &str = if cfg!(target_os = "macos") { "-Wl,-dead_strip_dylibs" } else { "-Wl,--as-needed" };

#[test]
fn libraries_link_after_archives() {
    let e = Env::new("linkorder");
    let d = &e.dir;
    std::fs::write(d.join("answer.c"), "int c_answer(void) { return 42; }\n").unwrap();
    ok(Command::new("cc").args(["-shared", "-fPIC", "-o"]).arg(d.join(format!("libanswer.{}", std::env::consts::DLL_EXTENSION))).arg(d.join("answer.c")).output().unwrap(), "cc -shared");
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
            .args(["--cc", AS_NEEDED, "--cc"])
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
