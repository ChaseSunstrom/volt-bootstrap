//! Build a Volt package from a Cargo build script and call it from Rust. In `build.rs`:
//!
//! ```no_run
//! volt_build::Package::new("mathlib", "volt/mathlib").build();
//! ```
//!
//! and in the crate:
//!
//! ```ignore
//! include!(concat!(env!("OUT_DIR"), "/mathlib.rs")); // pub mod mathlib
//! ```
//!
//! `build` runs `voltc lib NAME --static` and `voltc bindings NAME --lang rust` into OUT_DIR and
//! tells Cargo to link the library. voltc comes from `$VOLTC`, else the PATH; std from `$VOLT_STD`,
//! else voltc's own.
use std::path::{Path, PathBuf};
use std::process::Command;

/// a Volt package: its name and the directory of its .volt files
pub struct Package {
    name: String,
    dir: PathBuf,
    std: Option<PathBuf>,
}

impl Package {
    pub fn new(name: &str, dir: impl AsRef<Path>) -> Package {
        Package { name: name.to_string(), dir: dir.as_ref().to_path_buf(), std: None }
    }

    /// std from dir (instead of $VOLT_STD or voltc's own)
    pub fn std(mut self, dir: impl AsRef<Path>) -> Package {
        self.std = Some(dir.as_ref().to_path_buf());
        self
    }

    /// builds the library and the bindings (a failure stops the build script with voltc's message)
    pub fn build(&self) {
        if let Err(e) = self.try_build() {
            panic!("volt-build: {e}");
        }
    }

    /// what build does, as a Result
    pub fn try_build(&self) -> Result<(), String> {
        let out = PathBuf::from(std::env::var("OUT_DIR").map_err(|_| "OUT_DIR isn't set: run this from a build script".to_string())?);
        let voltc = std::env::var("VOLTC").unwrap_or_else(|_| "voltc".into());
        let dir = std::fs::canonicalize(&self.dir).map_err(|e| format!("{}: {e}", self.dir.display()))?;
        let pkg = format!("{}={}", self.name, dir.display());
        let mut common: Vec<String> = vec!["--pkg".into(), pkg];
        if let Some(s) = self.std.clone().or_else(|| std::env::var("VOLT_STD").ok().map(PathBuf::from)) {
            common.extend(["--std".into(), s.display().to_string()]);
        }
        let lib = out.join(format!("lib{}.a", self.name));
        let raw = out.join(format!("{}_bindings.rs", self.name));
        let run = |args: Vec<String>| -> Result<(), String> {
            let o = Command::new(&voltc).args(&args).output().map_err(|e| format!("can't run {voltc} (set $VOLTC to it): {e}"))?;
            if !o.status.success() {
                return Err(format!("voltc {} failed:\n{}", args.join(" "), String::from_utf8_lossy(&o.stderr)));
            }
            Ok(())
        };
        let mut a = vec!["lib".to_string(), self.name.clone()];
        a.extend(common.iter().cloned());
        a.extend(["--static".into(), "-o".into(), lib.display().to_string()]);
        run(a)?;
        let mut a = vec!["bindings".to_string(), self.name.clone()];
        a.extend(common.iter().cloned());
        a.extend(["--lang".into(), "rust".into(), "-o".into(), raw.display().to_string()]);
        run(a)?;
        // the bindings as `pub mod NAME` (their #![allow] goes on the module: include! can't take it)
        let text = std::fs::read_to_string(&raw).map_err(|e| e.to_string())?;
        let (attrs, body): (Vec<&str>, Vec<&str>) = text.lines().partition(|l| l.starts_with("#!["));
        let mut m = String::new();
        for a in attrs {
            m.push_str(&format!("#{}\n", &a[2..]));
        }
        m.push_str(&format!("pub mod {} {{\n{}\n}}\n", self.name, body.join("\n")));
        std::fs::write(out.join(format!("{}.rs", self.name)), m).map_err(|e| e.to_string())?;
        println!("cargo:rustc-link-search=native={}", out.display());
        println!("cargo:rustc-link-lib=static={}", self.name);
        // the runtime's threads and math (libpthread before glibc 2.34)
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rerun-if-changed={}", dir.display());
        println!("cargo:rerun-if-env-changed=VOLTC");
        println!("cargo:rerun-if-env-changed=VOLT_STD");
        Ok(())
    }
}
