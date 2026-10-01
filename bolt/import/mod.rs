// bolt import: the other side of `use LANG { "..." } as NAME;` in Volt source. voltc runs
//
//     bolt import LANG --as NAME --from DIR --out OUT [--release] -- ARGS...
//
// (DIR: the importing file's directory, which relative ARGS start from) and reads what it writes:
// OUT/import.volt, the Volt declarations of namespace NAME, whose bodies call the glue, and
// OUT/import.flags, what a program using them links, one flag a line. The glue is generated from
// the other language's own declarations, so nothing there needs marking up for Volt. Nothing is
// redone while the sources are as they were.
use std::path::{Path, PathBuf};

mod glue;
mod rust;
mod zig;

/// one import, as voltc asked for it
pub struct Req {
    pub lang: String,
    pub alias: String,
    pub from: PathBuf,
    pub out: PathBuf,
    pub release: bool,
    pub args: Vec<String>,
}

/// what an import gives voltc
pub struct Made {
    pub volt: String,
    pub flags: Vec<String>,
    /// the files it was made from: what voltc's output is rebuilt for (OUT/import.deps)
    pub deps: Vec<PathBuf>,
}

/// bolt import's entry: the exit code
pub fn main(argv: &[String]) -> i32 {
    match parse(argv).and_then(|r| run(&r)) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("{e}");
            1
        }
    }
}

fn parse(argv: &[String]) -> Result<Req, String> {
    let usage = "usage: bolt import LANG --as NAME --from DIR --out DIR [--release] -- ARGS...";
    let mut it = argv.iter();
    let lang = it.next().ok_or(usage)?.clone();
    let (mut alias, mut from, mut out, mut release, mut args) = (None, None, None, false, Vec::new());
    while let Some(a) = it.next() {
        match a.as_str() {
            "--as" => alias = it.next().cloned(),
            "--from" => from = it.next().map(PathBuf::from),
            "--out" => out = it.next().map(PathBuf::from),
            "--release" => release = true,
            "--" => {
                args.extend(it.by_ref().cloned());
            }
            _ => return Err(usage.into()),
        }
    }
    Ok(Req { lang, alias: alias.ok_or(usage)?, from: from.unwrap_or_else(|| ".".into()), out: out.ok_or(usage)?, release, args })
}

fn run(r: &Req) -> Result<(), String> {
    std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
    match r.lang.as_str() {
        "rust" => rust::import(r),
        "zig" => zig::import(r),
        other => Err(format!("there's no `use {other}`: the languages Volt imports are c (use {{ \"x.h\" }}), cpp, rust and zig")),
    }
}

/// an argument's path: as it is when absolute, else from the importing file's directory
pub fn arg_path(r: &Req, a: &str) -> PathBuf {
    let p = Path::new(a);
    let p = if p.is_absolute() { p.to_path_buf() } else { r.from.join(p) };
    std::fs::canonicalize(&p).unwrap_or(p)
}

/// what the sources are now (each file's path, size and modification time, plus `extra`): an import
/// is redone when this changes
pub fn stamp(files: &[PathBuf], extra: &str) -> String {
    let mut s = format!("bolt {} {extra}\n", env!("CARGO_PKG_VERSION"));
    // bolt itself: a new bolt may write the glue differently
    let me = std::env::current_exe().ok();
    for f in me.iter().chain(files) {
        let m = std::fs::metadata(f).ok();
        let t = m.as_ref().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_nanos());
        s.push_str(&format!("{} {} {t}\n", f.display(), m.map_or(0, |m| m.len())));
    }
    s
}

/// whether OUT has this import's results for sources stamped `st`
pub fn fresh(r: &Req, st: &str) -> bool {
    std::fs::read_to_string(r.out.join("stamp")).is_ok_and(|s| s == st)
        && ["import.volt", "import.flags", "import.deps"].iter().all(|f| r.out.join(f).is_file())
        // the library the flags start with: gone when its target directory was cleaned
        && std::fs::read_to_string(r.out.join("import.flags")).is_ok_and(|f| f.lines().next().is_some_and(|l| !l.starts_with('/') || Path::new(l).is_file()))
}

/// writes the results, then the stamp that says they're current
pub fn save(r: &Req, m: &Made, st: &str) -> Result<(), String> {
    crate::build::write_if_changed(&r.out.join("import.volt"), &m.volt)?;
    crate::build::write_if_changed(&r.out.join("import.flags"), &(m.flags.join("\n") + "\n"))?;
    let deps: Vec<String> = m.deps.iter().filter(|d| d.exists()).map(|d| d.display().to_string()).collect();
    crate::build::write_if_changed(&r.out.join("import.deps"), &(deps.join("\n") + "\n"))?;
    crate::build::write_if_changed(&r.out.join("stamp"), st)
}

/// a Volt keyword can't be a name: `match` becomes `match_` (and so do the hooks delete and copy,
/// for a method)
pub fn volt_name(n: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "var", "val", "static", "public", "internal", "attach", "struct", "enum", "fn", "error", "trait", "comptime", "async", "await", "suspend", "resume", "extern", "export",
        "namespace", "use", "as", "this", "move", "copy", "if", "else", "for", "in", "while", "loop", "break", "continue", "return", "match", "default", "try", "catch", "defer",
        "errdefer", "true", "false", "null", "delete", "type",
    ];
    if KEYWORDS.contains(&n) {
        format!("{n}_")
    } else {
        n.to_string()
    }
}
