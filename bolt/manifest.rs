// bolt.toml: a package (its targets, dependencies, features and std) or a workspace (its members
// and the profiles they build with), plus the semantic versions dependencies ask for. Paths in a
// manifest are relative to its directory.
use crate::toml::{self, Table, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

// ---------- versions ----------

/// a package version, MAJOR.MINOR.PATCH (a -pre or +build suffix is kept for display, not compared)
#[derive(Clone)]
pub struct Version {
    pub nums: [u64; 3],
    pub text: String,
}

pub fn version(s: &str) -> Result<Version, String> {
    let core = s.split(['-', '+']).next().unwrap_or("");
    let nums: Vec<u64> = core.split('.').map(|p| p.parse().ok()).collect::<Option<_>>().ok_or(format!("version '{s}' should look like 1.2.3"))?;
    let [a, b, c] = nums[..] else { return Err(format!("version '{s}' should look like 1.2.3")) };
    Ok(Version { nums: [a, b, c], text: s.to_string() })
}

/// a version requirement like Cargo's: comma-separated comparisons, each ^ (the default), ~, =,
/// >, >=, < or <= and a version that may stop early (1, 1.2) or end in a wildcard (1.*, *)
#[derive(Clone)]
pub struct Req {
    pub text: String,
    /// each comparison as [lo, hi): the lowest version it allows and the first one it doesn't
    ranges: Vec<(Option<[u64; 3]>, Option<[u64; 3]>)>,
}

impl Req {
    pub fn matches(&self, v: &Version) -> bool {
        self.ranges.iter().all(|(lo, hi)| lo.is_none_or(|l| v.nums >= l) && hi.is_none_or(|h| v.nums < h))
    }
}

pub fn req(s: &str) -> Result<Req, String> {
    let bad = || format!("version requirement '{s}' isn't one bolt understands (like ^1.2, ~1.2.3, >=1, <2, 1.*)");
    let mut ranges = Vec::new();
    for part in s.split(',').map(str::trim) {
        let (mut op, rest) = ["^", "~", "=", ">=", "<=", ">", "<"].iter().find_map(|op| part.strip_prefix(op).map(|r| (*op, r.trim()))).unwrap_or(("^", part));
        let nums: Vec<&str> = rest.split('.').take_while(|p| *p != "*" && *p != "x" && *p != "X").collect();
        if nums.len() < rest.split('.').count() {
            // 1.2.* is =1.2
            if op != "^" && op != "=" {
                return Err(bad());
            }
            op = "=";
        }
        if nums.len() > 3 {
            return Err(bad());
        }
        let p: Vec<u64> = nums.iter().map(|n| n.parse().map_err(|_| bad())).collect::<Result<_, _>>()?;
        if p.is_empty() {
            if !matches!(rest, "*" | "x" | "X") {
                return Err(bad());
            }
            continue; // * allows anything
        }
        let full = |p: &[u64]| [p[0], *p.get(1).unwrap_or(&0), *p.get(2).unwrap_or(&0)];
        // p with component i raised by one and the rest dropped: 1.2.3 bumped at 1 is 1.3.0
        let bump = |i: usize| {
            let mut v = full(&p[..=i]);
            v[i] += 1;
            v
        };
        let last = p.len() - 1;
        let caret_at = p.iter().position(|n| *n != 0).unwrap_or(last);
        ranges.push(match op {
            "^" => (Some(full(&p)), Some(bump(caret_at))),
            "~" => (Some(full(&p)), Some(bump(last.min(1)))),
            "=" => (Some(full(&p)), Some(bump(last))),
            ">" => (Some(bump(last)), None),
            ">=" => (Some(full(&p)), None),
            "<" => (None, Some(full(&p))),
            _ => (None, Some(bump(last))), // <=
        });
    }
    Ok(Req { text: s.to_string(), ranges })
}

// ---------- packages ----------

/// which commit of a git dependency: the default branch, or a rev, branch or tag
pub enum GitRef {
    Default,
    Rev(String),
    Branch(String),
    Tag(String),
}

impl GitRef {
    /// what git rev-parse resolves, and bolt.lock records
    pub fn spec(&self) -> String {
        match self {
            GitRef::Default => String::new(),
            GitRef::Rev(r) => r.clone(),
            GitRef::Branch(b) => format!("refs/heads/{b}"),
            GitRef::Tag(t) => format!("refs/tags/{t}"),
        }
    }
    /// does it follow a branch (so bolt looks for new commits when nothing is locked)?
    pub fn moves(&self) -> bool {
        matches!(self, GitRef::Default | GitRef::Branch(_))
    }
}

/// where a dependency comes from
pub enum Source {
    Path(PathBuf),
    Git { url: String, at: GitRef },
}

/// one entry of [dependencies] or [dev-dependencies]
pub struct Dep {
    pub name: String,
    pub source: Source,
    pub req: Option<Req>,
    /// only built when a feature turns it on (dep:NAME)
    pub optional: bool,
    pub features: Vec<String>,
    pub default_features: bool,
    /// from [dev-dependencies]: for tests, examples and benches only
    pub dev: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Bin,
    Example,
    Test,
    Bench,
}

impl Kind {
    pub fn name(self) -> &'static str {
        ["bin", "example", "test", "bench"][self as usize]
    }
    /// where targets of this kind are found, and built under target/<profile>/
    pub fn dir(self) -> &'static str {
        ["src", "examples", "tests", "benches"][self as usize]
    }
}

/// an executable to build: a .volt file, or a directory whose .volt files make one program
pub struct Target {
    pub kind: Kind,
    pub name: String,
    pub path: PathBuf,
    pub required_features: Vec<String>,
}

/// [std] in bolt.toml: the std voltc finds itself, another directory, or none
pub enum StdChoice {
    Default,
    Path(PathBuf),
    None,
}

/// a package's bolt.toml
pub struct Manifest {
    pub dir: PathBuf,
    pub name: String,
    pub version: Version,
    pub description: Option<String>,
    pub lib: Option<PathBuf>,
    /// [lib] kind: "shared" and "static" add self-contained libraries for other languages to the
    /// Volt one (voltc lib --shared/--static); bindings: the languages to write declarations for
    pub lib_kinds: Vec<String>,
    pub bindings: Vec<String>,
    pub targets: Vec<Target>,
    pub deps: Vec<Dep>,
    /// each feature and what it turns on; optional dependencies nothing names as dep:X get a feature X
    pub features: BTreeMap<String, Vec<String>>,
    pub std: StdChoice,
    /// precompile std into target/<profile>/deps/libstd.a (default) instead of compiling it into each program
    pub std_prebuilt: bool,
    pub build_files: Vec<PathBuf>,
    pub default_run: Option<String>,
}

impl Manifest {
    /// the targets of one kind
    pub fn of(&self, kind: Kind) -> impl Iterator<Item = &Target> {
        self.targets.iter().filter(move |t| t.kind == kind)
    }
    pub fn dep(&self, name: &str, dev: bool) -> Option<&Dep> {
        self.deps.iter().find(|d| d.name == name && d.dev == dev)
    }
}

/// a lowercase Volt name (package and dependency names become namespaces)
pub fn ident(s: &str) -> bool {
    s.chars().next().is_some_and(|c| c.is_ascii_lowercase() || c == '_') && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// a target or feature name: it becomes a file name or a --cfg value
fn plain(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// keys a table may have: anything else is probably a typo
fn only(t: &Table, what: &str, keys: &[&str]) -> Result<(), String> {
    match t.keys().find(|k| !keys.contains(&k.as_str())) {
        Some(k) => Err(format!("unknown key '{k}' in {what} (known: {})", keys.join(", "))),
        None => Ok(()),
    }
}

/// t[k] as a string: None when it's missing, an error when it isn't a string
fn get_str(t: &Table, k: &str, what: &str) -> Result<Option<String>, String> {
    match t.get(k) {
        None => Ok(None),
        Some(Value::Str(s)) => Ok(Some(s.clone())),
        Some(_) => Err(format!("{what}.{k} should be a string")),
    }
}

fn get_bool(t: &Table, k: &str, what: &str) -> Result<Option<bool>, String> {
    match t.get(k) {
        None => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(format!("{what}.{k} should be true or false")),
    }
}

/// t[k] as a list of strings (empty when missing)
fn get_strs(t: &Table, k: &str, what: &str) -> Result<Vec<String>, String> {
    match t.get(k) {
        None => Ok(Vec::new()),
        Some(Value::Array(a)) => a.iter().map(|v| v.as_str().map(String::from).ok_or(format!("{what}.{k} should be a list of strings"))).collect(),
        Some(_) => Err(format!("{what}.{k} should be a list of strings")),
    }
}

/// a parsed bolt.toml: a package, a workspace, or both
pub struct File {
    pub package: Option<Manifest>,
    pub workspace: Option<WorkspaceDecl>,
    pub profiles: Table,
}

/// [workspace]: member directories (a * in a path component matches any name)
pub struct WorkspaceDecl {
    pub members: Vec<String>,
    pub exclude: Vec<String>,
    pub default_members: Vec<String>,
}

pub fn read(dir: &Path) -> Result<File, String> {
    let file = dir.join("bolt.toml");
    let src = std::fs::read_to_string(&file).map_err(|e| format!("can't read {}: {e}", file.display()))?;
    let t = toml::parse(&src).map_err(|e| format!("{}: {e}", file.display()))?;
    parse(dir, &t).map_err(|e| format!("{}: {e}", file.display()))
}

/// dir/bolt.toml, which has to be a package
pub fn load(dir: &Path) -> Result<Manifest, String> {
    read(dir)?.package.ok_or(format!("{} is a workspace without a [package]", dir.join("bolt.toml").display()))
}

pub fn parse(dir: &Path, t: &Table) -> Result<File, String> {
    only(t, "bolt.toml", &["package", "lib", "bin", "example", "test", "bench", "dependencies", "dev-dependencies", "features", "std", "build", "workspace", "profile"])?;
    let workspace = match t.get("workspace") {
        Some(w) => {
            let w = w.as_table().ok_or("[workspace] should be a table")?;
            only(w, "[workspace]", &["members", "exclude", "default-members"])?;
            Some(WorkspaceDecl { members: get_strs(w, "members", "workspace")?, exclude: get_strs(w, "exclude", "workspace")?, default_members: get_strs(w, "default-members", "workspace")? })
        }
        None => None,
    };
    let profiles = match t.get("profile") {
        Some(Value::Table(p)) => p.clone(),
        Some(_) => return Err("[profile] should hold tables like [profile.release]".into()),
        None => Table::new(),
    };
    let package = match t.get("package") {
        Some(_) => Some(package(dir, t)?),
        None if workspace.is_some() => {
            if let Some(k) = t.keys().find(|k| *k != "workspace" && *k != "profile") {
                return Err(format!("[{k}] needs a [package]"));
            }
            None
        }
        None => return Err("missing [package]".into()),
    };
    Ok(File { package, workspace, profiles })
}

/// the package part of a bolt.toml. Without [[bin]], src/ (when present) is the package's
/// executable, and without [lib], lib/ (when present) its library; examples/, tests/ and benches/
/// hold one target per .volt file or subdirectory
fn package(dir: &Path, t: &Table) -> Result<Manifest, String> {
    let pkg = t.get("package").and_then(Value::as_table).ok_or("[package] should be a table")?;
    only(pkg, "[package]", &["name", "version", "description", "authors", "license", "repository", "default-run"])?;
    let name = get_str(pkg, "name", "package")?.ok_or("[package] needs a name")?;
    if !ident(&name) {
        return Err(format!("package name '{name}' has to be a Volt name (lowercase letters, digits, _): it becomes a namespace"));
    }
    let version = version(&get_str(pkg, "version", "package")?.unwrap_or("0.0.0".into()))?;
    let (mut lib_kinds, mut bindings) = (Vec::new(), Vec::new());
    let lib = match t.get("lib") {
        Some(Value::Table(l)) => {
            only(l, "[lib]", &["path", "kind", "bindings"])?;
            lib_kinds = get_strs(l, "kind", "lib")?;
            if let Some(k) = lib_kinds.iter().find(|k| !["volt", "shared", "static"].contains(&k.as_str())) {
                return Err(format!("[lib] kind '{k}' isn't volt, shared or static"));
            }
            bindings = get_strs(l, "bindings", "lib")?;
            if let Some(b) = bindings.iter().find(|b| !["c", "cpp", "rust", "zig", "python"].contains(&b.as_str())) {
                return Err(format!("[lib] bindings '{b}' isn't c, cpp, rust, zig or python"));
            }
            Some(dir.join(get_str(l, "path", "lib")?.unwrap_or("lib".into())))
        }
        Some(_) => return Err("[lib] should be a table".into()),
        None if dir.join("lib").is_dir() => Some(dir.join("lib")),
        None => None,
    };
    let mut targets = Vec::new();
    for kind in [Kind::Bin, Kind::Example, Kind::Test, Kind::Bench] {
        let mut found = Vec::new();
        if kind != Kind::Bin {
            for e in std::fs::read_dir(dir.join(kind.dir())).into_iter().flatten().flatten() {
                let p = e.path();
                let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                if p.is_dir() || p.extension().is_some_and(|x| x == "volt") {
                    found.push(Target { kind, name: stem, path: p, required_features: Vec::new() });
                }
            }
        }
        for b in t.get(kind.name()).and_then(Value::as_array).unwrap_or(&[]) {
            let what = format!("[[{}]]", kind.name());
            let b = b.as_table().ok_or(format!("{what} entries are tables"))?;
            only(b, &what, &["name", "path", "required-features"])?;
            let n = match (get_str(b, "name", kind.name())?, kind) {
                (Some(n), _) => n,
                (None, Kind::Bin) => name.clone(),
                (None, _) => return Err(format!("{what} needs a name")),
            };
            let p = match get_str(b, "path", kind.name())? {
                Some(p) => dir.join(p),
                None if kind == Kind::Bin => dir.join("src"),
                None if dir.join(kind.dir()).join(&n).is_dir() => dir.join(kind.dir()).join(&n),
                None => dir.join(kind.dir()).join(format!("{n}.volt")),
            };
            found.retain(|f| f.name != n);
            found.push(Target { kind, name: n, path: p, required_features: get_strs(b, "required-features", kind.name())? });
        }
        if kind == Kind::Bin && found.is_empty() && dir.join("src").exists() {
            found.push(Target { kind, name: name.clone(), path: dir.join("src"), required_features: Vec::new() });
        }
        if let Some(bad) = found.iter().find(|f| !plain(&f.name)) {
            return Err(format!("{} name '{}' can only have letters, digits, _ and -", kind.name(), bad.name));
        }
        found.sort_by(|a, b| a.name.cmp(&b.name));
        targets.extend(found);
    }
    let mut deps = Vec::new();
    for (section, dev) in [("dependencies", false), ("dev-dependencies", true)] {
        let Some(v) = t.get(section) else { continue };
        let table = v.as_table().ok_or(format!("[{section}] should be a table"))?;
        for (dn, v) in table {
            deps.push(dependency(dir, dn, v, dev)?);
            if *dn == name {
                return Err(format!("package {name} can't depend on itself"));
            }
        }
    }
    let mut features: BTreeMap<String, Vec<String>> = BTreeMap::new();
    if let Some(f) = t.get("features") {
        for (k, v) in f.as_table().ok_or("[features] should be a table")? {
            if !plain(k) {
                return Err(format!("feature name '{k}' can only have letters, digits, _ and -"));
            }
            let list = v.as_array().ok_or(format!("feature {k} should be a list"))?;
            features.insert(k.clone(), list.iter().map(|s| s.as_str().map(String::from).ok_or(format!("feature {k} should list strings"))).collect::<Result<_, _>>()?);
        }
    }
    // what each feature turns on has to exist
    let normal = |n: &str| deps.iter().find(|d| d.name == n && !d.dev);
    for (k, list) in &features {
        for item in list {
            let ok = if let Some(d) = item.strip_prefix("dep:") {
                normal(d).is_some_and(|d| d.optional)
            } else if let Some((d, _)) = item.split_once('/') {
                normal(d.trim_end_matches('?')).is_some()
            } else {
                features.contains_key(item) || normal(item).is_some_and(|d| d.optional)
            };
            if !ok {
                return Err(format!("feature {k} turns on '{item}', which isn't a feature, dep:OPTIONAL_DEPENDENCY or DEPENDENCY/FEATURE"));
            }
        }
    }
    // an optional dependency nothing turns on with dep:X is its own feature
    let named: Vec<String> = features.values().flatten().filter_map(|i| i.strip_prefix("dep:").map(String::from)).collect();
    for d in deps.iter().filter(|d| d.optional && !named.contains(&d.name)) {
        features.entry(d.name.clone()).or_insert_with(|| vec![format!("dep:{}", d.name)]);
    }
    let (mut std, mut std_prebuilt) = (StdChoice::Default, true);
    if let Some(s) = t.get("std") {
        let s = s.as_table().ok_or("[std] should be a table")?;
        only(s, "[std]", &["path", "none", "prebuilt"])?;
        if let Some(p) = get_str(s, "path", "std")? {
            std = StdChoice::Path(dir.join(p));
        }
        if get_bool(s, "none", "std")? == Some(true) {
            std = StdChoice::None;
        }
        std_prebuilt = get_bool(s, "prebuilt", "std")?.unwrap_or(true);
    }
    let mut build_files = Vec::new();
    if let Some(b) = t.get("build") {
        let b = b.as_table().ok_or("[build] should be a table")?;
        only(b, "[build]", &["files"])?;
        build_files = get_strs(b, "files", "build")?.iter().map(|f| dir.join(f)).collect();
    }
    let default_run = get_str(pkg, "default-run", "package")?;
    let description = get_str(pkg, "description", "package")?;
    Ok(Manifest { dir: dir.to_path_buf(), name, version, description, lib, lib_kinds, bindings, targets, deps, features, std, std_prebuilt, build_files, default_run })
}

fn dependency(dir: &Path, dn: &str, v: &Value, dev: bool) -> Result<Dep, String> {
    if !ident(dn) {
        return Err(format!("dependency name '{dn}' has to be a Volt name"));
    }
    let d = match v {
        Value::Table(d) => d,
        Value::Str(_) => return Err(format!("dependency {dn}: bolt has no registry; give {{ path = \"..\" }} or {{ git = \"..\" }}")),
        _ => return Err(format!("dependency {dn} should be {{ path = \"..\" }} or {{ git = \"..\" }}")),
    };
    only(d, &format!("dependency {dn}"), &["path", "git", "rev", "branch", "tag", "version", "optional", "features", "default-features"])?;
    let at = match (get_str(d, "rev", dn)?, get_str(d, "branch", dn)?, get_str(d, "tag", dn)?) {
        (None, None, None) => GitRef::Default,
        (Some(r), None, None) => GitRef::Rev(r),
        (None, Some(b), None) => GitRef::Branch(b),
        (None, None, Some(t)) => GitRef::Tag(t),
        _ => return Err(format!("dependency {dn}: give at most one of rev, branch and tag")),
    };
    let source = match (get_str(d, "path", dn)?, get_str(d, "git", dn)?) {
        (Some(p), None) if matches!(at, GitRef::Default) => Source::Path(dir.join(p)),
        (Some(_), None) => return Err(format!("dependency {dn}: rev, branch and tag are for git dependencies")),
        (None, Some(url)) => Source::Git { url, at },
        _ => return Err(format!("dependency {dn} needs exactly one of path or git")),
    };
    let optional = get_bool(d, "optional", dn)?.unwrap_or(false);
    if dev && optional {
        return Err(format!("dev-dependency {dn} can't be optional"));
    }
    Ok(Dep {
        name: dn.to_string(),
        source,
        req: get_str(d, "version", dn)?.map(|r| req(&r)).transpose().map_err(|e| format!("dependency {dn}: {e}"))?,
        optional,
        features: get_strs(d, "features", dn)?,
        default_features: get_bool(d, "default-features", dn)?.unwrap_or(true),
        dev,
    })
}

// ---------- workspaces ----------

/// the packages one command works on: a workspace root and its members, or a lone package
pub struct Workspace {
    pub root: PathBuf,
    pub members: Vec<Manifest>,
    /// the members a command without -p or --workspace means
    pub default: Vec<usize>,
    /// [profile.*] of the root manifest
    pub profiles: Table,
}

/// the workspace of the package in `start` (bolt.toml there or in a parent directory): the nearest
/// enclosing [workspace] that lists it, else the package alone
pub fn workspace(start: Option<&Path>) -> Result<Workspace, String> {
    let dir = match start {
        Some(p) => {
            let dir = if p.file_name().is_some_and(|f| f == "bolt.toml") { p.parent().unwrap_or(Path::new(".")) } else { p };
            canon(dir)?
        }
        None => {
            let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
            cwd.ancestors().find(|d| d.join("bolt.toml").is_file()).ok_or("no bolt.toml here or in any parent directory")?.to_path_buf()
        }
    };
    let file = read(&dir)?;
    // a package's workspace: the nearest parent whose [workspace] members include it
    let (root, root_file) = if file.workspace.is_some() {
        (dir.clone(), file)
    } else {
        let mut found = None;
        for up in dir.ancestors().skip(1).filter(|d| d.join("bolt.toml").is_file()) {
            let f = read(up)?;
            if let Some(w) = &f.workspace {
                if members(up, w)?.contains(&dir) {
                    found = Some((up.to_path_buf(), f));
                    break;
                }
            }
        }
        match found {
            Some(rf) => rf,
            None => {
                let m = file.package.ok_or("missing [package]")?;
                return Ok(Workspace { root: dir, members: vec![m], default: vec![0], profiles: file.profiles });
            }
        }
    };
    let decl = root_file.workspace.as_ref().unwrap();
    let mut ms: Vec<Manifest> = Vec::new();
    let mut dirs = Vec::new();
    if let Some(p) = root_file.package {
        dirs.push(root.clone());
        ms.push(p);
    }
    for d in members(&root, decl)? {
        if d != root {
            ms.push(load(&d)?);
            dirs.push(d);
        }
    }
    for (i, m) in ms.iter().enumerate() {
        if let Some(j) = ms[..i].iter().position(|o| o.name == m.name) {
            return Err(format!("two workspace members are called '{}' ({} and {})", m.name, dirs[j].display(), dirs[i].display()));
        }
    }
    // in a member's directory: that member; at the root: default-members, else the root's own
    // package, else every member
    let default = if dir != root {
        vec![dirs.iter().position(|d| *d == dir).unwrap()]
    } else if !decl.default_members.is_empty() {
        let mut v = Vec::new();
        for pat in &decl.default_members {
            let found = glob(&root, pat)?;
            if found.is_empty() {
                return Err(format!("default-members: '{pat}' names no directory"));
            }
            for d in found {
                v.push(dirs.iter().position(|x| *x == d).ok_or(format!("default member {} isn't a workspace member", d.display()))?);
            }
        }
        v
    } else if ms.first().is_some_and(|m| m.dir == root) {
        vec![0]
    } else {
        (0..ms.len()).collect()
    };
    Ok(Workspace { root, members: ms, default, profiles: root_file.profiles })
}

fn canon(p: &Path) -> Result<PathBuf, String> {
    p.canonicalize().map_err(|e| format!("{}: {e}", p.display()))
}

/// the member directories [workspace] lists, minus the excluded ones
fn members(root: &Path, w: &WorkspaceDecl) -> Result<Vec<PathBuf>, String> {
    let mut out = Vec::new();
    let mut skip = Vec::new();
    for pat in &w.exclude {
        skip.extend(glob(root, pat)?);
    }
    for pat in &w.members {
        for d in glob(root, pat)? {
            if !skip.contains(&d) && !out.contains(&d) && d.join("bolt.toml").is_file() {
                out.push(d);
            }
        }
    }
    Ok(out)
}

/// the directories `pattern` names under root; a component with * matches any directory name
/// (with the text around the * as prefix and suffix)
fn glob(root: &Path, pattern: &str) -> Result<Vec<PathBuf>, String> {
    let mut cur = vec![root.to_path_buf()];
    for part in pattern.split('/').filter(|p| !p.is_empty() && *p != ".") {
        let mut next = Vec::new();
        for d in &cur {
            match part.split_once('*') {
                None => next.push(d.join(part)),
                Some((pre, post)) => {
                    let mut names: Vec<PathBuf> = std::fs::read_dir(d).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
                    names.retain(|p| p.file_name().map(|n| n.to_string_lossy()).is_some_and(|n| n.len() >= pre.len() + post.len() && n.starts_with(pre) && n.ends_with(post)));
                    names.sort();
                    next.extend(names);
                }
            }
        }
        cur = next;
    }
    cur.into_iter().filter(|d| d.is_dir()).map(|d| canon(&d)).collect()
}

// ---------- profiles ----------

/// how a profile builds: voltc --release, --leak-check and --backend, and extra C compiler flags
pub struct Profile {
    pub name: String,
    /// target/<dir>
    pub dir: String,
    pub optimize: bool,
    pub leak_check: bool,
    pub backend: Option<String>,
    pub cc_flags: Vec<String>,
}

/// profile `name`: a built-in one (dev, release, test, bench) or [profile.NAME], which inherits
/// from another; [profile.dev] and the others adjust the built-in ones
pub fn profile(tables: &Table, name: &str) -> Result<Profile, String> {
    fn get(tables: &Table, name: &str, depth: usize) -> Result<Profile, String> {
        if depth > 8 {
            return Err(format!("profile {name} inherits from itself"));
        }
        let t = match tables.get(name) {
            Some(Value::Table(t)) => Some(t),
            Some(_) => return Err(format!("[profile.{name}] should be a table")),
            None => None,
        };
        let what = format!("profile.{name}");
        let mut p = match (name, t.and_then(|t| t.get("inherits"))) {
            ("dev", None) => Profile { name: "dev".into(), dir: "debug".into(), optimize: false, leak_check: false, backend: None, cc_flags: Vec::new() },
            ("release", None) => Profile { name: "release".into(), dir: "release".into(), optimize: true, leak_check: false, backend: None, cc_flags: Vec::new() },
            ("test", None) => get(tables, "dev", depth + 1)?,
            ("bench", None) => get(tables, "release", depth + 1)?,
            (_, Some(Value::Str(parent))) => {
                let mut p = get(tables, parent, depth + 1)?;
                p.dir = name.to_string();
                p
            }
            (_, Some(_)) => return Err(format!("{what}.inherits should be a profile name")),
            (_, None) if t.is_some() => return Err(format!("[profile.{name}] needs inherits = \"dev\" or \"release\"")),
            _ => return Err(format!("no profile '{name}' (dev, release, test, bench, or define [profile.{name}])")),
        };
        p.name = name.to_string();
        if let Some(t) = t {
            only(t, &format!("[{what}]"), &["inherits", "optimize", "leak-check", "backend", "cc-flags"])?;
            p.optimize = get_bool(t, "optimize", &what)?.unwrap_or(p.optimize);
            p.leak_check = get_bool(t, "leak-check", &what)?.unwrap_or(p.leak_check);
            if let Some(b) = get_str(t, "backend", &what)? {
                if b != "c" && b != "llvm" {
                    return Err(format!("{what}.backend is c or llvm, not '{b}'"));
                }
                p.backend = Some(b);
            }
            p.cc_flags.extend(get_strs(t, "cc-flags", &what)?);
        }
        Ok(p)
    }
    get(tables, name, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requirements() {
        let ok = |r: &str, v: &str| req(r).unwrap().matches(&version(v).unwrap());
        assert!(ok("1.2", "1.9.0") && !ok("1.2", "2.0.0") && !ok("1.2", "1.1.9"));
        assert!(ok("^0.2.3", "0.2.9") && !ok("^0.2.3", "0.3.0") && ok("^0.0.3", "0.0.3") && !ok("^0.0.3", "0.0.4"));
        assert!(ok("~1.2", "1.2.7") && !ok("~1.2", "1.3.0") && ok("~1", "1.9.0"));
        assert!(ok("=1.2.3", "1.2.3") && !ok("=1.2.3", "1.2.4") && ok("1.*", "1.5.0") && !ok("1.*", "2.0.0"));
        assert!(ok(">=0.3.1, <0.4", "0.3.1") && !ok(">=0.3.1, <0.4", "0.4.0") && ok(">1", "2.0.0") && !ok(">1", "1.9.9"));
        assert!(ok("<=1.2", "1.2.9") && !ok("<=1.2", "1.3.0") && ok("*", "7.0.0"));
        assert!(req("1.2.3.4").is_err() && req("abc").is_err() && version("1.2").is_err());
    }
}
