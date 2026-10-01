//! What the test harnesses that build voltc (the compiler written in Volt) share.

use std::process::Command;

/// An llvm-config for a copy of this system's LLVM moved into `dir` (headers and libraries symlinked),
/// its library renamed so a link only succeeds through the flags it reports: how LLVM looks on Debian
/// and Ubuntu (/usr/lib/llvm-N), wherever it really is. None without an llvm-config.
#[allow(dead_code)]
pub fn relocated_llvm_config(dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let ask = |what: &str| {
        let tool = std::env::var("LLVM_CONFIG").unwrap_or("llvm-config".into());
        let out = Command::new(tool).args(["--link-shared", what]).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    };
    let (inc, lib, libs) = (ask("--includedir")?, ask("--libdir")?, ask("--libs")?);
    let llvm = std::path::Path::new(&lib).join(format!("lib{}.so", libs.split_whitespace().next()?.strip_prefix("-l")?));
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir.join("include")).ok()?;
    std::fs::create_dir_all(dir.join("lib")).ok()?;
    use std::os::unix::fs::symlink;
    for h in ["llvm-c", "clang-c"] {
        symlink(std::path::Path::new(&inc).join(h), dir.join("include").join(h)).ok()?;
    }
    symlink(llvm.canonicalize().ok()?, dir.join("lib/libLLVMrelocated.so")).ok()?;
    let clang = std::path::Path::new(&lib).join("libclang.so");
    if clang.exists() {
        symlink(clang.canonicalize().ok()?, dir.join("lib/libclang.so")).ok()?;
    }
    let (i, l) = (dir.join("include").display().to_string(), dir.join("lib").display().to_string());
    let script = dir.join("llvm-config");
    let body = format!("#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --includedir) echo {i};; --libdir) echo {l};; --libs) echo -lLLVMrelocated;; esac; done\n");
    std::fs::write(&script, body).ok()?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).ok()?;
    Some(script)
}

/// `--cc` args linking libLLVM and libclang wherever this system keeps them, as voltc/build.volt
/// does for bolt: llvm-config says where ($LLVM_CONFIG, else llvm-config-22, else llvm-config on
/// PATH); without one, the default paths
pub fn llvm_cc_args() -> Vec<String> {
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
        Err(_) => from("llvm-config-22").or_else(|| from("llvm-config")).unwrap_or_else(|| vec!["-lLLVM".into(), "-lclang".into()]),
    };
    flags.into_iter().flat_map(|f| ["--cc".to_string(), f]).collect()
}
