// The self-hosted compiler (voltc/src, built by the bootstrap compiler) must agree with the Rust one:
// the same canonical parse tree for every .volt file in the repo (errors included), and the same
// `check` result (diagnostic text and exit code) for every test program and example.
mod common;
use std::path::{Path, PathBuf};
use std::process::Command;

/// every .volt file under dir, skipping hidden directories and target/
fn volt_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        if p.is_dir() {
            if !name.starts_with('.') && name != "target" {
                volt_files(&p, out);
            }
        } else if name.ends_with(".volt") {
            out.push(p);
        }
    }
}

/// voltc/src built by the bootstrap compiler; removed when dropped
struct Stage1(PathBuf);

impl Stage1 {
    fn build(tag: &str) -> Stage1 {
        let bin = env!("CARGO_BIN_EXE_voltc-bootstrap");
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let exe = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("voltc-stage1-{tag}-{}", std::process::id()));
        let mut srcs = Vec::new();
        volt_files(&root.join("voltc/src"), &mut srcs);
        let b = Command::new(bin).arg("build").args(&srcs).args(common::llvm_cc_args()).arg("-o").arg(&exe).output().unwrap();
        assert!(b.status.success(), "building voltc/src failed:\n{}", String::from_utf8_lossy(&b.stderr));
        Stage1(exe)
    }
}

impl Drop for Stage1 {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// stage1's `check` prints the same diagnostics and exits the same as the bootstrap's on every test and
/// example; then a few stage1-only checks
#[test]
fn self_hosted_checker_matches() {
    let bin = env!("CARGO_BIN_EXE_voltc-bootstrap");
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let exe = Stage1::build("check");
    let mut files = Vec::new();
    for dir in ["tests/fail", "tests/run", "tests/diag", "examples"] {
        volt_files(&root.join(dir), &mut files);
    }
    files.sort();
    // C++ imports are the self-hosted voltc's alone (tests/interop.rs checks them)
    files.retain(|f| !common::imports_foreign(&std::fs::read_to_string(f).unwrap_or_default()));
    let std_dir = root.join("std");
    let mut bad = Vec::new();
    for f in &files {
        let want = Command::new(bin).arg("check").arg(f).arg("--std").arg(&std_dir).output().unwrap();
        let got = Command::new(&exe.0).arg("check").arg(f).arg("--std").arg(&std_dir).output().unwrap();
        if want.stderr != got.stderr || want.status.code() != got.status.code() {
            bad.push(format!("{}:\n  want: {}\n  got:  {}", f.display(), String::from_utf8_lossy(&want.stderr).trim(), String::from_utf8_lossy(&got.stderr).trim()));
        }
    }
    // it checks itself too
    let mut srcs = Vec::new();
    volt_files(&root.join("voltc/src"), &mut srcs);
    let own = Command::new(&exe.0).arg("check").args(&srcs).arg("--std").arg(&std_dir).output().unwrap();
    assert!(own.status.success(), "the self-hosted checker rejects its own sources:\n{}", String::from_utf8_lossy(&own.stderr));
    // the readable C: emit-c -o DIR of tests/cgen/point.volt matches the reviewed files in tests/cgen/point
    // (volt.h from its types on: the prelude before them has its own tests), and builds and runs.
    // VOLT_BLESS=1 rewrites them
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("cgen-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let e = Command::new(&exe.0).args(["emit-c", "tests/cgen/point.volt", "--no-std", "-o"]).arg(&dir).current_dir(root).output().unwrap();
    assert!(e.status.success(), "emit-c -o: {}", String::from_utf8_lossy(&e.stderr));
    let snap = root.join("tests/cgen/point");
    let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
    names.sort();
    for n in &names {
        let mut text = std::fs::read_to_string(dir.join(n)).unwrap();
        if n == "volt.h" {
            text = text[text.find("// ---------- types").expect("volt.h has a types section")..].to_string();
        }
        if std::env::var_os("VOLT_BLESS").is_some() {
            std::fs::create_dir_all(&snap).unwrap();
            std::fs::write(snap.join(n), &text).unwrap();
        } else {
            let want = std::fs::read_to_string(snap.join(n)).unwrap_or_default();
            assert!(want == text, "tests/cgen/point/{n} differs from emit-c's:\n{text}");
        }
    }
    let prog = dir.join("prog");
    let cc = Command::new("cc").arg("-Wall").arg("-Werror").arg("-o").arg(&prog).arg(dir.join("program.c")).output().unwrap();
    assert!(cc.status.success(), "cc program.c: {}", String::from_utf8_lossy(&cc.stderr));
    let run = Command::new(&prog).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&run.stdout), "4 6 12 3\n");
    let _ = std::fs::remove_dir_all(&dir);
    // $CC with a wrapper word (see tests/cc_env.rs), for reading headers and building
    let cc = Command::new(&exe.0).args(["run", "tests/run/c_import.volt", "--std"]).arg(&std_dir).env("CC", "env cc").current_dir(root).output().unwrap();
    assert!(cc.status.success(), "CC='env cc': {}", String::from_utf8_lossy(&cc.stderr));
    assert!(bad.is_empty(), "self-hosted checker differs on:\n{}", bad.join("\n"));
}

/// C structs Volt can't read all of (a bitfield, a __typeof__ field, an anonymous member): libclang
/// gives their layout, so both backends build them; and C unions, laid out as C does
#[test]
fn partial_struct_layouts() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let std_dir = root.join("std");
    let exe = Stage1::build("partial");
    let unions = std::fs::read_to_string(root.join("tests/run/c_union.volt")).unwrap();
    let unions: Vec<&str> = unions.lines().filter_map(|l| l.strip_prefix("// expect: ")).collect();
    let unions = unions.join("\n");
    for (file, want) in [("tests/llvm/partial_struct.volt", "3"), ("tests/llvm/partial_typeof.volt", "4"), ("tests/run/c_union.volt", unions.as_str())] {
        for backend in ["c", "llvm"] {
            let o = Command::new(&exe.0).args(["run", file, "--std"]).arg(&std_dir).args(["--backend", backend]).current_dir(root).output().unwrap();
            assert!(o.status.success() && String::from_utf8_lossy(&o.stdout).trim() == want, "{file}, {backend} backend: {}", String::from_utf8_lossy(&o.stderr));
        }
    }
}

/// voltc built with --release (as `bolt build --release` makes it) works, and so does the release
/// voltc it builds of itself: std builds as a library, and every tests/run program prints what it
/// expects (the LLVM backend too). Release builds free memory for real, without the debug allocator's
/// quarantine and poisoning, so they're where a use after free shows
#[test]
fn release_voltc_works() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let std_dir = root.join("std");
    let tmp = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("release-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let mut srcs = Vec::new();
    volt_files(&root.join("voltc/src"), &mut srcs);
    let (first, second) = (tmp.join("voltc-r1"), tmp.join("voltc-r2"));
    for (by, out) in [(Path::new(env!("CARGO_BIN_EXE_voltc-bootstrap")), &first), (first.as_path(), &second)] {
        let b = Command::new(by).arg("build").args(&srcs).arg("--std").arg(&std_dir).arg("--release").args(common::llvm_cc_args()).arg("-o").arg(out).output().unwrap();
        assert!(b.status.success(), "{} building voltc --release failed:\n{}", by.display(), String::from_utf8_lossy(&b.stderr));
    }
    let o = Command::new(&second).args(["lib", "std", "--std"]).arg(&std_dir).arg("-o").arg(tmp.join("libstd.a")).output().unwrap();
    assert!(o.status.success(), "release voltc lib std: {}", String::from_utf8_lossy(&o.stderr));
    let mut runs: Vec<(PathBuf, &str)> = std::fs::read_dir(root.join("tests/run")).unwrap().map(|e| (e.unwrap().path(), "c")).collect();
    runs.push((root.join("tests/run/temp_lifetimes.volt"), "llvm"));
    runs.push((root.join("tests/run/typeid.volt"), "llvm"));
    runs.push((root.join("tests/run/closure_fn_drop.volt"), "llvm"));
    let mut bad = Vec::new();
    for (file, backend) in &runs {
        let text = std::fs::read_to_string(file).unwrap();
        let want: Vec<&str> = text.lines().filter_map(|l| l.strip_prefix("// expect: ")).map(|l| l.trim_end()).collect();
        if want.is_empty() {
            continue;
        }
        let flags: Vec<&str> = text.lines().find_map(|l| l.strip_prefix("// flags:")).map(|f| f.split_whitespace().collect()).unwrap_or_default();
        let o = Command::new(&second).arg("run").arg(file).arg("--std").arg(&std_dir).args(["--backend", backend]).args(&flags).current_dir(root).output().unwrap();
        let out = String::from_utf8_lossy(&o.stdout);
        if out.lines().map(|l| l.trim_end()).collect::<Vec<_>>() != want {
            bad.push(format!("{} ({backend}):\n{out}{}", file.display(), String::from_utf8_lossy(&o.stderr)));
        }
    }
    assert!(bad.is_empty(), "the release voltc built by itself differs on:\n{}", bad.join("\n"));
    hot_profiles(&second, &tmp);
    bare_metal(&second, &std_dir);
    let _ = std::fs::remove_dir_all(&tmp);
}

/// the bare-metal examples with that voltc: each board's blinky (for both of each board's targets),
/// debug and release, built with no C compiler at all ($CC is false) and run under qemu, prints its
/// expected.txt and exits 0. A board whose qemu (or ld.lld) isn't installed is skipped: its run.sh
/// exits 77
fn bare_metal(voltc: &Path, std_dir: &Path) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/bare-metal");
    for (board, target) in [("riscv-virt", "riscv32-none"), ("riscv-virt", "riscv64-none"), ("cortex-m3", "thumbv7m-none"), ("cortex-m3", "thumbv7em-none")] {
        let dir = root.join(board);
        for release in ["", "1"] {
            let o = Command::new(dir.join("run.sh")).env("VOLTC", voltc).env("VOLT_STD", std_dir).env("RELEASE", release).env("TARGET", target).env("CC", "false").output().unwrap();
            if o.status.code() == Some(77) {
                eprintln!("bare metal: skipped {board} {target} (no qemu or ld.lld)");
                break;
            }
            let want = std::fs::read_to_string(dir.join("expected.txt")).unwrap();
            let out = String::from_utf8_lossy(&o.stdout);
            assert!(o.status.success() && out == want, "bare metal {board} {target} (release: {}) exited {:?}, printed:\n{out}{}", release == "1", o.status.code(), String::from_utf8_lossy(&o.stderr));
        }
        let _ = std::fs::remove_file(dir.join("blinky.elf"));
    }
}

/// bolt hot with that voltc: a program's hot function and line are found and named the Volt way, and
/// only a --profiler build has the sampler
fn hot_profiles(voltc: &Path, tmp: &Path) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    if !cfg!(target_os = "linux") || ["llvm-symbolizer", "addr2line"].iter().all(|t| Command::new(t).arg("--version").output().is_err()) {
        return; // the sampler is Linux-only, and naming samples needs one of those
    }
    let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["hot", "tests/hot/spin.volt"]).current_dir(root).env("VOLTC", voltc).env("VOLT_STD", root.join("std")).output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success(), "bolt hot failed:\n{out}{}", String::from_utf8_lossy(&o.stderr));
    // work by its Volt name though gcc copies it (work.constprop.0); mix, only ever inlined, says so
    assert!(out.contains("  work (tests/hot/spin.volt:11)\n"), "bolt hot didn't name work:\n{out}");
    assert!(out.contains("  mix (tests/hot/spin.volt:6), inlined\n"), "bolt hot didn't mark mix inlined:\n{out}");
    assert!(out.contains("tests/hot/spin.volt:8  return i * 2654435761"), "bolt hot didn't find the hot line:\n{out}");
    assert!(out.contains("main -> work -> mix"), "bolt hot didn't find the path:\n{out}");
    // a hot leaf keeps its caller in the path: --profiler builds with clang, which gives leaves frame pointers
    if Command::new("clang").arg("--version").output().is_ok() {
        let o = Command::new(env!("CARGO_BIN_EXE_bolt")).args(["hot", "tests/hot/leaf.volt"]).current_dir(root).env("VOLTC", voltc).env("VOLT_STD", root.join("std")).env_remove("CC").output().unwrap();
        let out = String::from_utf8_lossy(&o.stdout);
        assert!(o.status.success() && out.contains("main -> work -> spin"), "bolt hot lost a leaf's caller:\n{out}{}", String::from_utf8_lossy(&o.stderr));
    }
    // a normal build: no sampler in it
    let exe = tmp.join("spin");
    let b = Command::new(voltc).args(["build", "--release"]).arg(root.join("tests/hot/spin.volt")).arg("--std").arg(root.join("std")).arg("-o").arg(&exe).output().unwrap();
    assert!(b.status.success(), "{}", String::from_utf8_lossy(&b.stderr));
    if let Ok(syms) = Command::new("nm").arg(&exe).output() {
        assert!(!String::from_utf8_lossy(&syms.stdout).contains("volt_prof_"), "a build without --profiler has the sampler");
    }
}

/// both compilers, built into a package's target/<profile>/ (as bolt builds voltc), find the std three
/// levels up; and a library the linker can't find is reported as that, not as a voltc bug
#[test]
fn toolchain_layout_and_link_errors() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let tmp = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("layout-{}", std::process::id()));
    let bin_dir = tmp.join("voltc/target/release");
    std::fs::create_dir_all(&bin_dir).unwrap();
    std::os::unix::fs::symlink(root.join("std"), tmp.join("std")).unwrap();
    let tiny = tmp.join("tiny.volt");
    std::fs::write(&tiny, "fn main() -> void {}\n").unwrap();
    let stage1 = Stage1::build("layout");
    for (name, from) in [("voltc-bootstrap", Path::new(env!("CARGO_BIN_EXE_voltc-bootstrap"))), ("voltc", stage1.0.as_path())] {
        let exe = bin_dir.join(name);
        std::fs::copy(from, &exe).unwrap();
        let o = Command::new(&exe).arg("std-dir").env_remove("VOLT_STD").output().unwrap();
        let found = String::from_utf8_lossy(&o.stdout).trim().to_string();
        assert!(o.status.success() && Path::new(&found) == root.join("std").canonicalize().unwrap(), "{name} std-dir: {found} {}", String::from_utf8_lossy(&o.stderr));
        let o = Command::new(&exe).arg("build").arg(&tiny).args(["--cc", "-lvolt_no_such_lib", "-o"]).arg(tmp.join("tiny")).output().unwrap();
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(!o.status.success() && err.contains("failed: a library above wasn't found") && !err.contains("voltc bug"), "{name}: {err}");
    }
    // an LLVM build of a program importing no C compiles the runtime once into Volt's cache, then
    // links it from there
    let cache = tmp.join("cache");
    for _ in 0..2 {
        let o = Command::new(&stage1.0).arg("build").arg(&tiny).args(["--backend", "llvm", "--std"]).arg(root.join("std")).arg("-o").arg(tmp.join("tiny_llvm")).env("VOLT_CACHE", &cache).output().unwrap();
        assert!(o.status.success(), "LLVM build with a runtime cache: {}", String::from_utf8_lossy(&o.stderr));
        assert!(Command::new(tmp.join("tiny_llvm")).status().unwrap().success());
    }
    let objs: Vec<String> = std::fs::read_dir(cache.join("runtime")).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
    assert!(objs.len() == 1 && objs[0].starts_with("rt-") && objs[0].ends_with(".o"), "the runtime cache holds {objs:?}");
    let _ = std::fs::remove_dir_all(&tmp);
}

/// stage1's `parse --sexp` prints the same tree (or error) as the bootstrap's for every .volt file in the repo
#[test]
fn self_hosted_parser_matches() {
    let bin = env!("CARGO_BIN_EXE_voltc-bootstrap");
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let stage1 = Stage1::build("parse");
    let exe = &stage1.0;

    let mut files = Vec::new();
    volt_files(root, &mut files);
    files.sort();
    assert!(files.len() > 100, "only {} .volt files found", files.len());
    let mut bad = Vec::new();
    for f in &files {
        let want = Command::new(bin).arg("parse").arg(f).arg("--sexp").output().unwrap();
        let got = Command::new(exe).arg("parse").arg(f).arg("--sexp").output().unwrap();
        if want.stdout != got.stdout || want.status.code() != got.status.code() {
            bad.push(f.display().to_string());
        }
    }
    assert!(bad.is_empty(), "self-hosted parser differs on:\n{}", bad.join("\n"));
}

/// voltc/src/runtime_c.volt: the C prelude and runtime (runtime/prelude.h, runtime/runtime.h) as Volt
/// strings, for the self-hosted C backend. VOLT_REGEN=1 rewrites it.
fn runtime_c_volt(root: &Path) -> String {
    let lit = |p: &str| {
        let text = std::fs::read_to_string(root.join(p)).unwrap();
        let mut s = String::from("\"");
        for c in text.chars() {
            match c {
                '\\' => s.push_str("\\\\"),
                '"' => s.push_str("\\\""),
                '\n' => s.push_str("\\n"),
                '\t' => s.push_str("\\t"),
                c => s.push(c),
            }
        }
        s + "\""
    };
    format!(
        "// Generated from runtime/prelude.h and runtime/runtime.h by tests/selfhost.rs (VOLT_REGEN=1 cargo test --test selfhost); don't edit.\n\nval PRELUDE_H: str = {};\n\nval RUNTIME_H: str = {};\n",
        lit("runtime/prelude.h"),
        lit("runtime/runtime.h")
    )
}

/// voltc/src/runtime_c.volt matches the runtime headers
#[test]
fn runtime_text_in_sync() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let want = runtime_c_volt(root);
    let path = root.join("voltc/src/runtime_c.volt");
    if std::env::var_os("VOLT_REGEN").is_some() {
        std::fs::write(&path, &want).unwrap();
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(have == want, "voltc/src/runtime_c.volt is stale: VOLT_REGEN=1 cargo test --test selfhost runtime_text_in_sync");
}

/// the runtime (its threads, atomics and allocator included) compiles for every 64-bit OS and CPU it
/// supports, debug and release. It includes no libc headers, so clang's own freestanding ones do
#[test]
fn runtime_compiles_for_every_target() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("runtime-targets");
    std::fs::create_dir_all(&dir).unwrap();
    let unit = dir.join("unit.c");
    std::fs::write(&unit, "#include \"prelude.h\"\n#include \"runtime.h\"\n").unwrap();
    let targets = [
        "x86_64-linux-gnu", "aarch64-linux-gnu", "riscv64-linux-gnu", "x86_64-apple-macos11", "arm64-apple-macos11",
        "x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc", "x86_64-w64-windows-gnu", "x86_64-unknown-freebsd",
        // 32-bit: no __int128, so i128 is _BitInt(128)
        "i686-linux-gnu", "armv7-linux-gnueabihf", "i686-pc-windows-msvc",
    ];
    for t in targets {
        for debug in [true, false] {
            let mut cc = Command::new("clang");
            cc.args([&format!("--target={t}"), "-ffreestanding", "-std=c11", "-Werror", "-Wall", "-Wno-unused-function", "-c"]);
            if debug {
                cc.arg("-DVOLT_DEBUG_ALLOC");
            }
            let o = cc.arg("-I").arg(root.join("runtime")).arg(&unit).arg("-o").arg(dir.join(format!("{t}.o"))).output().unwrap();
            assert!(o.status.success(), "the runtime doesn't compile for {t} (debug {debug}):\n{}", String::from_utf8_lossy(&o.stderr));
            // every print takes a lock that can wait, so what the runtime imports, every program links:
            // on Windows that's kernel32 only (WaitOnAddress is looked up; MinGW won't link it by default)
            if t.contains("windows") {
                let nm = Command::new("llvm-nm").arg("-u").arg(dir.join(format!("{t}.o"))).output().unwrap();
                let undefined = String::from_utf8_lossy(&nm.stdout);
                assert!(!undefined.contains("WaitOnAddress") && !undefined.contains("WakeByAddress"), "{t}: the runtime links WaitOnAddress:\n{undefined}");
            }
        }
    }
}

/// std's code for other systems (picked with @cfg("os") and "arch") compiles there: the programs using
/// its OS parts are emitted as C with --cfg os=X arch=Y and compiled for that target (not linked: those
/// systems aren't here), and what they leave for the linker has no Linux-only C functions in it. Unused
/// functions count too (-femit-all-decls): gcc at -O0, and the LLVM backend, keep them
#[test]
fn std_compiles_for_other_systems() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("std-targets");
    std::fs::create_dir_all(&dir).unwrap();
    let programs = ["std_net", "std_os", "std_random", "std_threads", "process_capture", "exe_path"];
    let targets = [
        ("windows", "x86_64", "x86_64-pc-windows-msvc"),
        ("windows", "aarch64", "aarch64-pc-windows-msvc"),
        ("macos", "aarch64", "arm64-apple-macos11"),
        ("macos", "x86_64", "x86_64-apple-macos11"),
        ("freebsd", "x86_64", "x86_64-unknown-freebsd"),
        ("linux", "aarch64", "aarch64-unknown-linux-gnu"),
    ];
    // only Linux's C library has these (glibc's errno, getline's GNU spelling aside)
    let linux_only = ["__errno_location"];
    // and Windows has none of POSIX's processes, directories, clocks or environment
    let posix_only = ["fork", "execvp", "waitpid", "pipe", "poll", "getline", "opendir", "readdir", "closedir", "clock_gettime", "nanosleep", "setenv", "unsetenv", "readlink", "getrandom", "__error", "mkdir", "access"];
    // and the other systems have none of Windows'
    let windows_only = ["_errno", "_mkdir", "_access", "_fseeki64", "_putenv_s", "_getcwd", "rand_s", "FindFirstFileA", "GetFileAttributesA", "MoveFileExA", "QueryPerformanceCounter", "CreateProcessA", "CreatePipe", "GetModuleFileNameA", "WSAStartup"];
    for (os, arch, target) in targets {
        for prog in programs {
            let name = format!("{prog}-{os}-{arch}");
            let c = dir.join(format!("{name}.c"));
            let o = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap"))
                .args(["emit-c", &format!("tests/run/{prog}.volt"), "--cfg", &format!("os={os}"), "--cfg", &format!("arch={arch}")])
                .current_dir(root)
                .output()
                .unwrap();
            assert!(o.status.success(), "emit-c {prog} for {os}: {}", String::from_utf8_lossy(&o.stderr));
            std::fs::write(&c, &o.stdout).unwrap();
            let obj = dir.join(format!("{name}.o"));
            let cc = Command::new("clang").arg(format!("--target={target}")).args(["-ffreestanding", "-w", "-c", "-femit-all-decls"]).arg(&c).arg("-o").arg(&obj).output().unwrap();
            assert!(cc.status.success(), "std's {os} code in {prog} doesn't compile for {target}:\n{}", String::from_utf8_lossy(&cc.stderr));
            let nm = Command::new("llvm-nm").args(["-u", "-j"]).arg(&obj).output().unwrap();
            // Mach-O puts an underscore before every C name
            let undefined: Vec<String> = String::from_utf8_lossy(&nm.stdout).lines().map(|l| if os == "macos" { l.strip_prefix('_').unwrap_or(l) } else { l }.to_string()).collect();
            let wrong: Vec<&String> = undefined
                .iter()
                .filter(|u| os != "linux" && linux_only.contains(&u.as_str()) || os == "windows" && posix_only.contains(&u.as_str()) || os != "windows" && windows_only.contains(&u.as_str()))
                .collect();
            assert!(wrong.is_empty(), "{prog} for {os} calls C functions that system doesn't have: {wrong:?}");
        }
    }
}

/// std::path's Windows rules run here: tests/cross/windows_paths.volt built with --cfg os=windows, with
/// the Windows functions std names (which it never calls) left unresolved by the linker
#[test]
fn windows_paths_run() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let file = "tests/cross/windows_paths.volt";
    let src = std::fs::read_to_string(root.join(file)).unwrap();
    let want: Vec<&str> = src.lines().filter_map(|l| l.strip_prefix("// expect: ")).collect();
    let o = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap"))
        .args(["run", file, "--cfg", "os=windows", "--cc", "-no-pie", "--cc", "-Wl,--unresolved-symbols=ignore-all"])
        .current_dir(root)
        .output()
        .unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && out.lines().collect::<Vec<_>>() == want, "std::path with Windows' rules printed:\n{out}{}", String::from_utf8_lossy(&o.stderr));
}

/// the self-hosted compiler reproduces itself (stage2 == stage3) and stage2 passes the golden suite.
/// LLVM is found through an llvm-config for a relocated copy of it, as on Debian and Ubuntu, so the
/// build file's flags and the bootstrap tool's $BOLT_CC_ARGS are what make it link
#[test]
fn bootstrap_reproduces_itself() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut bolt = Command::new(env!("CARGO_BIN_EXE_bolt"));
    if let Some(cfg) = common::relocated_llvm_config(&Path::new(env!("CARGO_TARGET_TMPDIR")).join("relocated-llvm")) {
        bolt.env("LLVM_CONFIG", cfg);
    }
    let o = bolt
        .args(["build", "bootstrap"])
        .current_dir(root.join("voltc"))
        .env("VOLTC", env!("CARGO_BIN_EXE_voltc-bootstrap"))
        .env("BOLT_HOME", Path::new(env!("CARGO_TARGET_TMPDIR")).join("bolt-home"))
        .output()
        .unwrap();
    let (out, err) = (String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    assert!(o.status.success() && out.contains("stage2 == stage3"), "bolt build bootstrap failed\n--- stdout\n{out}\n--- stderr\n{err}");
}
