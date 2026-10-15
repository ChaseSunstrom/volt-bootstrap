//! What the test harnesses share: the stage-1 voltc they run (voltc/src built by the Rust bootstrap
//! compiler, stage 0) and how to link it against LLVM.

use std::process::Command;

/// How a command run with a time limit ended: its exit code (None when a signal stopped it), what it
/// printed, and whether the limit stopped it
#[allow(dead_code)]
pub struct Run {
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
}

#[allow(dead_code)]
impl Run {
    pub fn success(&self) -> bool {
        self.code == Some(0) && !self.timed_out
    }
}

/// cmd run for at most `secs` seconds (what GNU timeout did, on every system). A command still
/// running then is stopped with whatever it started: `voltc run`'s program is in its process group
/// (Unix) or its process tree (Windows)
#[allow(dead_code)]
pub fn run_for(cmd: &mut Command, secs: u64) -> Run {
    use std::io::Read;
    use std::process::Stdio;
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(cmd, 0);
    let mut child = cmd.spawn().unwrap_or_else(|e| panic!("can't run {:?}: {e}", cmd.get_program()));
    let id = child.id();
    let drain = |r: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut v = Vec::new();
            if let Some(mut r) = r {
                let _ = r.read_to_end(&mut v);
            }
            v
        })
    };
    let out = drain(child.stdout.take().map(|r| Box::new(r) as Box<dyn Read + Send>));
    let err = drain(child.stderr.take().map(|r| Box::new(r) as Box<dyn Read + Send>));
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(child.wait());
    });
    let mut timed_out = false;
    let status = match rx.recv_timeout(std::time::Duration::from_secs(secs)) {
        Ok(s) => s.unwrap(),
        Err(_) => {
            timed_out = true;
            stop_tree(id);
            rx.recv().unwrap().unwrap()
        }
    };
    Run { code: status.code(), stdout: out.join().unwrap(), stderr: err.join().unwrap(), timed_out }
}

/// SIGKILL to process group `id` (run_for made the command its leader)
#[cfg(unix)]
#[allow(dead_code)]
fn stop_tree(id: u32) {
    unsafe extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    unsafe {
        kill(-(id as i32), 9);
    }
}

#[cfg(not(unix))]
#[allow(dead_code)]
fn stop_tree(id: u32) {
    let _ = Command::new("taskkill").args(["/F", "/T", "/PID", &id.to_string()]).output();
}

/// An llvm-config for a copy of this system's LLVM moved into `dir` (headers and libraries symlinked),
/// its library renamed so a link only succeeds through the flags it reports: how LLVM looks on Debian
/// and Ubuntu (/usr/lib/llvm-N), wherever it really is. None without an llvm-config, and on systems
/// without .so libraries and symlinks
#[cfg(not(unix))]
#[allow(dead_code)]
pub fn relocated_llvm_config(_dir: &std::path::Path) -> Option<std::path::PathBuf> {
    None
}

#[cfg(unix)]
#[allow(dead_code)]
pub fn relocated_llvm_config(dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let ask = |what: &str| {
        let tool = std::env::var("LLVM_CONFIG").unwrap_or("llvm-config".into());
        let out = Command::new(tool).args(["--link-shared", what]).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    };
    let (inc, lib, libs) = (ask("--includedir")?, ask("--libdir")?, ask("--libs")?);
    let name = libs.split_whitespace().next()?.strip_prefix("-l")?;
    let llvm = std::path::Path::new(&lib).join(format!("lib{name}.so"));
    // the renamed library keeps LLVM's own name (LLVM-23) in it, so a build cached against another
    // LLVM sees its link flags change and is rebuilt
    let renamed = format!("relocated{name}");
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir.join("include")).ok()?;
    std::fs::create_dir_all(dir.join("lib")).ok()?;
    use std::os::unix::fs::symlink;
    for h in ["llvm-c", "clang-c"] {
        symlink(std::path::Path::new(&inc).join(h), dir.join("include").join(h)).ok()?;
    }
    symlink(llvm.canonicalize().ok()?, dir.join(format!("lib/lib{renamed}.so"))).ok()?;
    let clang = std::path::Path::new(&lib).join("libclang.so");
    if clang.exists() {
        symlink(clang.canonicalize().ok()?, dir.join("lib/libclang.so")).ok()?;
    }
    let (i, l) = (dir.join("include").display().to_string(), dir.join("lib").display().to_string());
    let script = dir.join("llvm-config");
    let body = format!("#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --includedir) echo {i};; --libdir) echo {l};; --libs) echo -l{renamed};; esac; done\n");
    std::fs::write(&script, body).ok()?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).ok()?;
    Some(script)
}

/// a program of the LLVM voltc is built with (clang, clang++): NAME from PATH, except on macOS, where
/// PATH's is Apple's clang (another LLVM, older): llvm-config's bindir ($LLVM_CONFIG, Homebrew's)
#[allow(dead_code)]
pub fn llvm_tool(name: &str) -> String {
    if !cfg!(target_os = "macos") {
        return name.into();
    }
    let tool = std::env::var("LLVM_CONFIG").unwrap_or("llvm-config".into());
    let out = Command::new(&tool).arg("--bindir").output().unwrap_or_else(|e| panic!("{tool} --bindir: {e}"));
    format!("{}/{name}", String::from_utf8_lossy(&out.stdout).trim())
}

/// `--cc` args linking libLLVM and libclang wherever this system keeps them, as voltc/build.volt
/// does for bolt: llvm-config says where ($LLVM_CONFIG, else llvm-config-23, else llvm-config on
/// PATH); without one, the default paths
pub fn llvm_cc_args() -> Vec<String> {
    // Windows: LLVM's release has no libLLVM to link whole; voltc takes LLVM's C API from LLVM-C.dll
    // and libclang.dll, through their import libraries (which MinGW's linker reads)
    if cfg!(windows) {
        let tool = std::env::var("LLVM_CONFIG").unwrap_or("llvm-config".into());
        let ask = |what: &str| {
            let out = Command::new(&tool).arg(what).output().ok()?;
            out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        };
        let (Some(inc), Some(lib)) = (ask("--includedir"), ask("--libdir")) else {
            panic!("{tool} didn't answer --includedir and --libdir: set $LLVM_CONFIG to LLVM's llvm-config.exe");
        };
        let flags = [format!("-I{inc}"), format!("-L{lib}"), "-l:LLVM-C.lib".into(), "-l:libclang.lib".into()];
        return flags.into_iter().flat_map(|f| ["--cc".to_string(), f]).collect();
    }
    let ask = |tool: &str, what: &str| {
        let out = Command::new(tool).args(["--link-shared", what]).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    };
    let from = |tool: &str| {
        let (inc, lib, libs) = (ask(tool, "--includedir")?, ask(tool, "--libdir")?, ask(tool, "--libs")?);
        let mut flags = Vec::new();
        // the default paths need no flags (and -I/usr/include can reorder the system headers)
        if inc != "/usr/include" {
            flags.push(format!("-I{inc}"));
        }
        if lib != "/usr/lib" && lib != "/usr/lib64" {
            flags.extend([format!("-L{lib}"), format!("-Wl,-rpath,{lib}")]);
        }
        flags.extend(libs.split_whitespace().map(String::from));
        flags.push("-lclang".into());
        Some(flags)
    };
    let flags = match std::env::var("LLVM_CONFIG") {
        Ok(tool) => from(&tool).unwrap_or_else(|| panic!("$LLVM_CONFIG ({tool}) didn't answer --includedir, --libdir and --libs")),
        Err(_) => from("llvm-config-23").or_else(|| from("llvm-config")).unwrap_or_else(|| vec!["-lLLVM".into(), "-lclang".into()]),
    };
    flags.into_iter().flat_map(|f| ["--cc".to_string(), f]).collect()
}

/// voltc/src built by the bootstrap compiler (stage 0), debug: the compiler the tests run. Built once
/// for a state of voltc/src, std and the bootstrap binary, whichever test binary gets there first (the
/// others wait on a lock file), and kept in CARGO_TARGET_TMPDIR for the next run
#[allow(dead_code)]
pub fn voltc() -> std::path::PathBuf {
    // a failed build is kept too, so the binary's other tests report it instead of building again
    static STAGE1: std::sync::OnceLock<Result<std::path::PathBuf, String>> = std::sync::OnceLock::new();
    STAGE1.get_or_init(build_stage1).clone().unwrap_or_else(|e| panic!("{e}"))
}

fn build_stage1() -> Result<std::path::PathBuf, String> {
    use std::hash::{Hash, Hasher};
    use std::path::{Path, PathBuf};
    fn volt_files(dir: &Path, out: &mut Vec<PathBuf>) {
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                volt_files(&p, out);
            } else if p.extension().is_some_and(|x| x == "volt") {
                out.push(p);
            }
        }
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let stage0 = Path::new(env!("CARGO_BIN_EXE_voltc-bootstrap"));
    let (mut srcs, mut stdf) = (Vec::new(), Vec::new());
    volt_files(&root.join("voltc/src"), &mut srcs);
    volt_files(&root.join("std"), &mut stdf);
    srcs.sort();
    stdf.sort();
    let cc = llvm_cc_args();
    let mut h = std::hash::DefaultHasher::new();
    for f in srcs.iter().chain(&stdf) {
        f.hash(&mut h);
        std::fs::read(f).unwrap().hash(&mut h);
    }
    let meta = std::fs::metadata(stage0).unwrap();
    (meta.len(), meta.modified().unwrap(), &cc).hash(&mut h);
    let tmp = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let exe = tmp.join(format!("voltc-stage1-{:016x}{}", h.finish(), std::env::consts::EXE_SUFFIX));
    let lock = std::fs::File::create(tmp.join("voltc-stage1.lock")).unwrap();
    lock.lock().unwrap();
    if exe.exists() {
        // its time is when a run last took it, so the clean-up below leaves it to runs still going
        let _ = std::fs::File::open(&exe).and_then(|f| f.set_modified(std::time::SystemTime::now()));
    } else {
        // the stage 1s of other source states go, once no run has taken one for two hours
        for e in std::fs::read_dir(tmp).unwrap().flatten() {
            let old = e.metadata().and_then(|m| m.modified()).is_ok_and(|t| t.elapsed().is_ok_and(|d| d.as_secs() > 7200));
            if old && e.file_name().to_string_lossy().starts_with("voltc-stage1-") {
                let _ = std::fs::remove_file(e.path());
            }
        }
        let part = exe.with_extension("part");
        let b = Command::new(stage0).arg("build").args(&srcs).args(&cc).arg("-o").arg(&part).output().unwrap();
        if !b.status.success() {
            return Err(format!("stage 0 failed to build voltc/src:\n{}", String::from_utf8_lossy(&b.stderr)));
        }
        std::fs::rename(&part, &exe).unwrap();
    }
    Ok(exe)
}
