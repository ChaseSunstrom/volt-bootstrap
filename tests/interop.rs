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
    let want = "dist 5 norm 5\nscaled 6 8\nhello, volt QUIET first\ngeom 10\nsum 7\ndoubled 2 4 6\nsquares 4 last 16\nwords 3 three\njoin a-b-c\nfind 2 true\nnickname lucky true\nor_default 5 -1\nparse 42\nbad ERROR(invalid digit found in string)\ndiv 3\nzero ERROR(1 / 0)\ncolor blue green\npixel 2 green 65\nperimeter 7 12 name tri\nside 4\nmissing ERROR(tri has no side 9)\nlongest tri\ncentroid 4.5\nconsumed 3 into tri\nproblem 3 clash 123\nsettings 4 mode Slow\nticks 2\n";
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("RUSTUP_TOOLCHAIN", rust_toolchain());
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
    }
    // one .rs file is a crate of its own (its `mod x;` files next to it)
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "single.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run single.volt"), "3 n=70\n", "a single .rs file ({backend})");
    }
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
    let want = "dist 5 norm 5\nscaled 6 8\n42 fastmath 10 1.5\nfirst QUIET\nsum 7\ndoubled 2 4 6\nsquares 4 last 16\njoin a-b-c\nfind 2 true\nor_default 5 -1\nparse 42\nbad ERROR(InvalidCharacter)\ndiv 3\nzero ERROR(DivisionByZero)\ncolor blue green\npixel 2 green\ntwice 42\nperimeter 7 10 name tri\nside 4\nmissing ERROR(NoSuchSide)\nlongest quad\nconsumed 2\nticks 2 3\n";
    let tools = |c: &mut Command| {
        c.env("VOLTC", &e.voltc).env("BOLT", env!("CARGO_BIN_EXE_bolt")).env("VOLT_CACHE", e.dir.join("cache")).env("BOLT_HOME", e.dir.join("bolthome")).env("ZIG", &zig);
    };
    for backend in ["c", "llvm"] {
        let mut c = Command::new(&e.voltc);
        c.args(["run", "--backend", backend, "main.volt"]).current_dir(&dir).env("VOLT_STD", Path::new(ROOT).join("std"));
        tools(&mut c);
        assert_eq!(ok(c.output().unwrap(), "voltc run"), want, "voltc run ({backend})");
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
fn cpp_import() {
    let e = Env::new("cpp");
    let want = "make 2 3\narea 6\nfields 5 6\nscaled 60 15\ncount 7 name rect\nmake 4 4\nkind 4 1\ntotal 46\ncopy 4 4\ncopied 16\ndrop 4 4\ndrop 4 4\ndrop 5 6\nadd 3 3.5\nbiggest 9 2.5\nbox 6\nenum 4 1\nsize 16\n";
    let want_std = "hello, volt 3\nfirst lorem\nsum 6.5\nrange 4 9\nvec 4 -6 6\neq true 10\nnode 4\ntaken 40\nshared 7 2\nbuffer abcd 4\nparse 42\nbad -1 trailing characters in '4x'\nerror EXCEPTION not positive\n";
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
