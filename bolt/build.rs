// Building one command's packages: std and every library that's on with `voltc lib`, then the
// executables with `voltc build`, each only when its inputs or its command changed, and independent
// ones in parallel. Also build files (Volt programs whose printed directives add sources, C inputs,
// executables and named steps), and running tests and benchmarks.
use crate::manifest::{self, ForeignKind, Kind, Profile, StdChoice, Target};
use crate::resolve::{self, Active, Graph, Lock, Want};
use crate::{Opts, fail, status};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Instant, SystemTime};

/// the compiler: $VOLTC, else voltc next to bolt, voltc on PATH, then voltc-bootstrap next to bolt
pub fn find_voltc() -> PathBuf {
    if let Some(p) = std::env::var_os("VOLTC") {
        return p.into();
    }
    let here = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf));
    let near = |name: &str| here.as_ref().map(|d| d.join(name)).filter(|p| p.is_file());
    let on_path = |name: &str| std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).map(|d| d.join(name)).find(|p| p.is_file());
    near("voltc").or_else(|| on_path("voltc")).or_else(|| near("voltc-bootstrap")).unwrap_or_else(|| PathBuf::from("voltc"))
}

/// every .volt file under `p` (or `p` itself), sorted
pub fn volt_files(p: &Path) -> Vec<PathBuf> {
    if p.is_file() {
        return vec![p.to_path_buf()];
    }
    let mut out = Vec::new();
    let mut dirs = vec![p.to_path_buf()];
    while let Some(d) = dirs.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let path = e.path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|x| x == "volt") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// an exclusive lock on `path` (created if needed), held until the file is dropped: two bolts
/// never share a git cache or a target directory at the same time
pub fn lock_file(path: &Path) -> std::fs::File {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap_or_else(|e| fail(format!("can't make {}: {e}", path.display())));
    let f = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(path).unwrap_or_else(|e| fail(format!("can't open {}: {e}", path.display())));
    f.lock().unwrap_or_else(|e| fail(format!("can't lock {}: {e}", path.display())));
    f
}

/// a command as the user would type it
pub fn show(c: &Command) -> String {
    let words = std::iter::once(c.get_program()).chain(c.get_args()).map(|a| {
        let a = a.to_string_lossy();
        if a.is_empty() || a.contains(|c: char| c.is_whitespace() || c == '\'' || c == '"') { format!("'{}'", a.replace('\'', "'\\''")) } else { a.into_owned() }
    });
    words.collect::<Vec<_>>().join(" ")
}

/// runs cmd (printing it with -v); fails with `what` if it doesn't succeed
/// a Cargo crate's library name: [lib] name, else the package's name with - as _
fn crate_lib_name(dir: &Path) -> Result<String, String> {
    let path = dir.join("Cargo.toml");
    let text = std::fs::read_to_string(&path).map_err(|e| format!("can't read {}: {e}", path.display()))?;
    let t = crate::toml::parse(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let get = |table: &str, key: &str| t.get(table).and_then(|v| v.as_table()).and_then(|v| v.get(key)).and_then(|v| v.as_str()).map(String::from);
    let name = get("lib", "name").or_else(|| get("package", "name")).ok_or(format!("{} has no [package] name", path.display()))?;
    Ok(name.replace('-', "_"))
}

/// every .zig file under dir
fn zig_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            zig_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "zig") {
            out.push(p);
        }
    }
}

/// the C compiler native modules are built with: $CC, else cc
fn c_compiler() -> String {
    std::env::var("CC").ok().filter(|c| !c.trim().is_empty()).unwrap_or_else(|| "cc".into())
}

/// the include directories a native module for lang (node, lua, ruby) is compiled against; none when
/// they aren't installed (for Lua, 5.4 or later)
fn module_includes(lang: &str) -> Option<Vec<String>> {
    let output = |cmd: &str, args: &[&str]| Command::new(cmd).args(args).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    match lang {
        "node" => {
            let own = output("node", &["-p", "require('path').join(process.execPath, '..', '..', 'include', 'node')"]).unwrap_or_default();
            [own.as_str(), "/usr/include/node", "/usr/local/include/node"].iter().find(|d| !d.is_empty() && Path::new(d).join("node_api.h").is_file()).map(|d| vec![d.to_string()])
        }
        "lua" => ["/usr/include", "/usr/include/lua5.5", "/usr/include/lua5.4", "/usr/local/include"].iter().find(|d| lua_version(Path::new(d)).is_some_and(|v| v >= 504)).map(|d| vec![d.to_string()]),
        "ruby" => {
            let dirs: Vec<String> = output("ruby", &["-e", "print RbConfig::CONFIG['rubyhdrdir'], ' ', RbConfig::CONFIG['rubyarchhdrdir']"])?.split_whitespace().map(String::from).collect();
            (dirs.len() == 2 && Path::new(&dirs[0]).join("ruby.h").is_file()).then_some(dirs)
        }
        _ => None,
    }
}

/// LUA_VERSION_NUM from the lua.h in dir (504 for 5.4)
fn lua_version(dir: &Path) -> Option<u32> {
    let text = std::fs::read_to_string(dir.join("lua.h")).ok()?;
    let line = text.lines().find(|l| l.trim_start().starts_with("#define LUA_VERSION_NUM"))?;
    line.split_whitespace().nth(2)?.parse().ok()
}

/// write text to path (and its directory) unless it already holds it, so its time only moves when
/// it changes
fn write_if_changed(path: &Path, text: &str) -> Result<(), String> {
    if std::fs::read_to_string(path).is_ok_and(|t| t == text) {
        return Ok(());
    }
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d).map_err(|e| format!("can't make {}: {e}", d.display()))?;
    }
    std::fs::write(path, text).map_err(|e| format!("can't write {}: {e}", path.display()))
}

pub fn run_checked(mut cmd: Command, what: &str) -> Result<(), String> {
    crate::verbose(&cmd);
    let st = cmd.status().map_err(|e| format!("can't run {what}: {e}"))?;
    if !st.success() {
        return Err(format!("{what} failed"));
    }
    Ok(())
}

/// runs f on each item, `jobs` at a time; the first error stops the rest
pub fn parallel<T: Send>(jobs: usize, items: Vec<T>, f: impl Fn(T) -> Result<(), String> + Sync) -> Result<(), String> {
    let queue = Mutex::new(items.into_iter());
    let err = Mutex::new(None);
    std::thread::scope(|s| {
        for _ in 0..jobs.max(1) {
            s.spawn(|| {
                while err.lock().unwrap().is_none() {
                    let Some(it) = queue.lock().unwrap().next() else { break };
                    if let Err(e) = f(it) {
                        err.lock().unwrap().get_or_insert(e);
                    }
                }
            });
        }
    });
    err.into_inner().unwrap().map_or(Ok(()), Err)
}

/// one compile: voltc with `args` makes `out`, unless out is newer than every input and was made by
/// this exact command (so switching std, profile, features or a dependency's path rebuilds it)
struct Job {
    out: PathBuf,
    inputs: Vec<PathBuf>,
    args: Vec<String>,
    /// the Compiling line
    what: String,
    /// what runs it: voltc, unless it's another tool (the C compiler, for a native module)
    program: Option<PathBuf>,
}

/// what makes `pkg`'s executables: its lib's package closure, and whether dev-dependencies count
#[derive(Clone)]
pub struct Exe {
    pub pkg: usize,
    pub kind: Kind,
    pub name: String,
    pub roots: Vec<PathBuf>,
    pub out: PathBuf,
}

/// one command's build: the resolved packages, what's on, the profile, where things go
pub struct Build {
    pub g: Graph,
    pub act: Active,
    /// the packages that are on, in build order
    pub order: Vec<usize>,
    /// the selected packages (-p, --workspace, or the one here)
    pub roots: Vec<usize>,
    pub profile: Profile,
    pub ws_root: PathBuf,
    /// target/<profile dir>
    pub target: PathBuf,
    pub voltc: PathBuf,
    pub jobs: usize,
    std: StdChoice,
    std_prebuilt: bool,
    /// voltc options from the command line (--message-format, --color, --backend)
    extra: Vec<String>,
    backend: Option<String>,
    /// prebuilt libraries: std, then packages by index
    std_lib: Option<PathBuf>,
    libs: HashMap<usize, PathBuf>,
    std_inputs: Vec<PathBuf>,
    inputs: HashMap<usize, Vec<PathBuf>>,
    /// each package's [foreign] libraries, once built: the C compiler flags that use them
    foreign_cc: HashMap<usize, Vec<String>>,
    _lock: std::fs::File,
}

impl Build {
    /// finds the workspace, locks its target directory, resolves every dependency (pinning git ones
    /// in bolt.lock) and turns on what the selected packages need; `dev` adds their dev-dependencies
    pub fn new(o: &Opts, profile: &str, dev: bool) -> Build {
        let ws = manifest::workspace(o.manifest_path.as_deref()).unwrap_or_else(|e| fail(e));
        let ws_root = ws.root.clone();
        let target_root = o.target_dir.clone().unwrap_or_else(|| ws_root.join("target"));
        let target_lock = lock_file(&target_root.join(".bolt-lock"));
        let profile = manifest::profile(&ws.profiles, o.profile.as_deref().unwrap_or(if o.release { "release" } else { profile })).unwrap_or_else(|e| fail(e));
        let default = ws.default.clone();
        let n_members = ws.members.len();
        let mut lock = Lock::read(&ws_root, o.offline).unwrap_or_else(|e| fail(e));
        let g = {
            let _cache = lock_file(&resolve::cache_dir().join("lock"));
            resolve::resolve(ws, &mut lock).unwrap_or_else(|e| fail(e))
        };
        lock.write(&ws_root, o.locked).unwrap_or_else(|e| fail(e));
        let roots: Vec<usize> = if o.workspace {
            (0..n_members).collect()
        } else if !o.packages.is_empty() {
            o.packages.iter().map(|p| *g.by_name.get(p).unwrap_or_else(|| fail(format!("no package '{p}' in this workspace")))).collect()
        } else {
            default
        };
        if roots.is_empty() {
            fail(format!("the workspace at {} has no members to build", ws_root.display()));
        }
        let wants = wants(&g, &roots, o, dev).unwrap_or_else(|e| fail(e));
        let act = resolve::activate(&g, &wants, dev).unwrap_or_else(|e| fail(e));
        let order = resolve::build_order(&g, &act).unwrap_or_else(|e| fail(e));
        // one std for the whole build: the selected packages have to agree on it
        let std_key = |p: usize| match &g.pkgs[p].m.std {
            StdChoice::Default => String::new(),
            StdChoice::Path(d) => d.canonicalize().unwrap_or(d.clone()).display().to_string(),
            StdChoice::None => "none".into(),
        };
        if let Some(&r) = roots.iter().find(|r| std_key(**r) != std_key(roots[0])) {
            fail(format!("packages {} and {} use different std ([std] in bolt.toml): build them separately", g.pkgs[roots[0]].m.name, g.pkgs[r].m.name));
        }
        let first = &g.pkgs[roots[0]].m;
        let voltc = find_voltc();
        // the default std, found once and passed as --std: so which one it was is part of every
        // command's stamp ($VOLT_STD pointing elsewhere rebuilds)
        let std = match &first.std {
            StdChoice::Default => {
                let out = Command::new(&voltc).arg("std-dir").output().unwrap_or_else(|e| fail(format!("can't run {}: {e}", voltc.display())));
                if out.status.success() { StdChoice::Path(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim())) } else { StdChoice::Default }
            }
            StdChoice::Path(p) => StdChoice::Path(p.clone()),
            StdChoice::None => StdChoice::None,
        };
        let std_prebuilt = first.std_prebuilt;
        let target = target_root.join(&profile.dir);
        std::fs::create_dir_all(target.join("deps")).unwrap_or_else(|e| fail(format!("can't make {}: {e}", target.display())));
        let mut extra = Vec::new();
        if let Some(f) = &o.message_format {
            extra.extend(["--message-format".to_string(), f.clone()]);
        }
        if let Some(c) = &o.color {
            extra.extend(["--color".to_string(), c.clone()]);
        }
        if let Some(n) = &o.error_limit {
            extra.extend(["--error-limit".to_string(), n.clone()]);
        }
        let backend = o.backend.clone().or(profile.backend.clone());
        Build {
            g,
            act,
            order,
            roots,
            profile,
            ws_root,
            target,
            voltc,
            jobs: o.jobs.unwrap_or_else(|| std::thread::available_parallelism().map_or(1, |n| n.get())),
            std,
            std_prebuilt,
            extra,
            backend,
            std_lib: None,
            libs: HashMap::new(),
            std_inputs: Vec::new(),
            inputs: HashMap::new(),
            foreign_cc: HashMap::new(),
            _lock: target_lock,
        }
    }

    /// voltc CMD with the std choice, the profile and the command line's options
    fn args(&self, cmd: &str) -> Vec<String> {
        let mut a = vec![cmd.to_string()];
        match &self.std {
            StdChoice::Default => {}
            StdChoice::Path(p) => a.extend(["--std".into(), p.display().to_string()]),
            StdChoice::None => a.push("--no-std".into()),
        }
        if self.profile.optimize {
            a.push("--release".into());
        }
        a.extend(self.extra.iter().cloned());
        a
    }

    /// --pkg, --link and --cfg for code that uses these packages; `own` is the package whose
    /// program files these are (its features are theirs too)
    fn pkg_args(&self, pkgs: &[usize], own: Option<usize>, link: bool) -> Vec<String> {
        let mut a = Vec::new();
        for &p in pkgs {
            let m = &self.g.pkgs[p].m;
            if let Some(lib) = &m.lib {
                a.extend(["--pkg".into(), format!("{}={}", m.name, lib.display())]);
            }
        }
        if link {
            if let Some(s) = &self.std_lib {
                a.extend(["--link".into(), format!("std={}", s.display())]);
            }
            for p in pkgs {
                if let Some(l) = self.libs.get(p) {
                    a.extend(["--link".into(), format!("{}={}", self.g.pkgs[*p].m.name, l.display())]);
                }
            }
        }
        for &p in pkgs.iter().filter(|p| self.g.pkgs[**p].m.lib.is_some()) {
            for f in &self.act.features[p] {
                a.extend(["--cfg".into(), format!("{}:feature={f}", self.g.pkgs[p].m.name)]);
            }
        }
        if let Some(p) = own {
            for f in &self.act.features[p] {
                a.extend(["--cfg".into(), format!("feature={f}")]);
            }
        }
        a
    }

    fn run_job(&self, j: Job) -> Result<(), String> {
        let stamp_path = PathBuf::from(format!("{}.cmd", j.out.display()));
        let program = j.program.as_ref().unwrap_or(&self.voltc);
        let stamp = format!("{}\n{}", program.display(), j.args.join("\n"));
        let t = mtime(&j.out);
        let fresh = t.is_some_and(|t| j.inputs.iter().all(|i| mtime(i).is_some_and(|m| m <= t)));
        if fresh && std::fs::read_to_string(&stamp_path).is_ok_and(|s| s == stamp) {
            return Ok(());
        }
        status("Compiling", &j.what);
        let _ = std::fs::remove_file(&stamp_path);
        if let Some(d) = j.out.parent() {
            std::fs::create_dir_all(d).map_err(|e| format!("can't make {}: {e}", d.display()))?;
        }
        let mut c = Command::new(program);
        c.args(&j.args);
        let live = crate::progress::start(&j.what);
        if live.is_none() {
            run_checked(c, &format!("compiling {}", j.what))?;
        } else {
            // on a terminal the live line is up: what the compiler prints goes above it, in colour
            // (not part of the stamp, so a terminal and a log don't rebuild each other's work)
            if j.program.is_none() && crate::ui().color && !j.args.iter().any(|a| a == "--color") {
                c.args(["--color", "always"]);
            }
            crate::verbose(&c);
            let o = c.output().map_err(|e| format!("can't run compiling {}: {e}", j.what))?;
            drop(live);
            crate::progress::above(&(String::from_utf8_lossy(&o.stdout).to_string() + &String::from_utf8_lossy(&o.stderr)));
            if !o.status.success() {
                return Err(format!("compiling {} failed", j.what));
            }
        }
        std::fs::write(&stamp_path, stamp).map_err(|e| format!("can't write {}: {e}", stamp_path.display()))
    }

    /// the std directory this build uses; None with [std] none (or when voltc has none)
    fn std_dir(&self) -> Option<PathBuf> {
        match &self.std {
            StdChoice::Path(p) => Some(p.clone()),
            _ => None,
        }
    }

    /// the packages whose libraries `pkg`'s code builds on (with dev: its dev-dependencies too)
    pub fn closure(&self, pkg: usize, dev: bool) -> Vec<usize> {
        self.act.closure(&self.g, pkg, dev, &self.order)
    }

    /// precompile std and the libraries of `pkgs` (in build order, each level in parallel)
    pub fn libraries(&mut self, pkgs: &[usize]) -> Result<(), String> {
        if self.std_inputs.is_empty() {
            if let Some(std) = self.std_dir() {
                // every library is built against std, prebuilt or not
                self.std_inputs = volt_files(&std);
                self.std_inputs.push(self.voltc.clone());
                if self.std_prebuilt {
                    let out = self.target.join("deps/libstd.a");
                    let mut args = self.args("lib");
                    args.extend(["std".into(), "-o".into(), out.display().to_string()]);
                    self.run_job(Job { out: out.clone(), inputs: self.std_inputs.clone(), args, what: format!("std ({})", std.display()), program: None })?;
                    self.std_lib = Some(out);
                }
            } else {
                self.std_inputs.push(self.voltc.clone());
            }
        }
        // a library's level: one more than its dependencies'; a level's libraries build together
        let mut level: HashMap<usize, usize> = HashMap::new();
        let todo: Vec<usize> = self.order.iter().copied().filter(|p| pkgs.contains(p) && self.g.pkgs[*p].m.lib.is_some() && !self.libs.contains_key(p)).collect();
        for &p in &self.order {
            let l = self.act.deps[p].iter().filter_map(|d| level.get(d)).max().map_or(0, |l| l + 1);
            level.insert(p, l);
        }
        let mut levels: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
        for p in todo {
            levels.entry(level[&p]).or_default().push(p);
        }
        for (_, ps) in levels {
            let mut jobs = Vec::new();
            let mut includes = HashMap::new();
            for &p in &ps {
                includes.insert(p, self.foreign_flags(p)?.into_iter().filter(|f| f.starts_with("-I")).collect::<Vec<_>>());
            }
            for &p in &ps {
                let m = &self.g.pkgs[p].m;
                let out = self.target.join(format!("deps/lib{}.a", m.name));
                let closure = self.closure(p, false);
                // rebuilt when it or anything it builds on changed
                let mut inputs = volt_files(m.lib.as_ref().unwrap());
                inputs.extend(self.std_inputs.iter().cloned());
                for d in closure.iter().filter(|d| **d != p) {
                    inputs.extend(self.inputs.get(d).cloned().unwrap_or_default());
                }
                let mut args = self.args("lib");
                args.push(m.name.clone());
                args.extend(self.pkg_args(&closure, None, true));
                for f in &includes[&p] {
                    args.extend(["--cc".into(), f.clone()]);
                }
                args.extend(["-o".into(), out.display().to_string()]);
                jobs.push((p, Job { out, inputs, args, what: format!("{} v{} ({})", m.name, m.version.text, m.dir.display()), program: None }));
            }
            for (p, j) in &jobs {
                self.inputs.insert(*p, j.inputs.clone());
            }
            let outs: Vec<(usize, PathBuf)> = jobs.iter().map(|(p, j)| (*p, j.out.clone())).collect();
            parallel(self.jobs, jobs, |(_, j)| self.run_job(j))?;
            self.libs.extend(outs);
        }
        Ok(())
    }

    /// where an executable goes: target/<profile>/NAME, or examples/, tests/, benches/ under it
    pub fn exe_path(&self, kind: Kind, name: &str) -> PathBuf {
        match kind {
            Kind::Bin => self.target.join(name),
            k => self.target.join(k.dir()).join(name),
        }
    }

    pub fn exe_of(&self, pkg: usize, t: &Target) -> Exe {
        Exe { pkg, kind: t.kind, name: t.name.clone(), roots: vec![t.path.clone()], out: self.exe_path(t.kind, &t.name) }
    }

    /// build executables (their libraries first); `plans` adds each package's build-file sources and C inputs
    pub fn executables(&mut self, exes: &[Exe], plans: &HashMap<usize, Plan>) -> Result<(), String> {
        let mut need = Vec::new();
        for e in exes {
            need.extend(self.closure(e.pkg, e.kind != Kind::Bin));
        }
        self.libraries(&need)?;
        let mut foreign: HashMap<usize, Vec<String>> = HashMap::new();
        for &p in &need {
            foreign.insert(p, self.foreign_flags(p)?);
        }
        let none = Plan::default();
        let mut jobs = Vec::new();
        for e in exes {
            let plan = plans.get(&e.pkg).unwrap_or(&none);
            let mut files: Vec<PathBuf> = e.roots.iter().flat_map(|r| volt_files(r)).collect();
            files.extend(plan.sources.iter().cloned());
            if files.is_empty() {
                return Err(format!("{} '{}' has no .volt files", e.kind.name(), e.name));
            }
            let closure = self.closure(e.pkg, e.kind != Kind::Bin);
            let mut inputs = files.clone();
            inputs.extend(self.std_inputs.iter().cloned());
            for p in &closure {
                inputs.extend(self.inputs.get(p).cloned().unwrap_or_default());
            }
            let mut args = self.args("build");
            if self.profile.leak_check {
                args.push("--leak-check".into());
            }
            if let Some(b) = &self.backend {
                args.extend(["--backend".into(), b.clone()]);
            }
            args.extend(files.iter().map(|f| f.display().to_string()));
            args.extend(self.pkg_args(&closure, Some(e.pkg), true));
            let uses: Vec<String> = closure.iter().flat_map(|p| foreign.get(p).cloned().unwrap_or_default()).collect();
            for a in self.profile.cc_flags.iter().chain(&plan.cc).chain(&uses) {
                args.extend(["--cc".into(), a.clone()]);
                if Path::new(a).is_file() {
                    inputs.push(a.into());
                }
            }
            args.extend(["-o".into(), e.out.display().to_string()]);
            let m = &self.g.pkgs[e.pkg].m;
            jobs.push(Job { out: e.out.clone(), inputs, args, what: format!("{} v{} ({} \"{}\")", m.name, m.version.text, e.kind.name(), e.name), program: None });
        }
        parallel(self.jobs, jobs, |j| self.run_job(j))
    }

    /// package p's [foreign] libraries, built (cargo for a Rust crate, zig build-lib for a Zig file)
    /// into target/<profile>/foreign with their headers written to foreign/include: the C compiler
    /// flags that find the headers and link the libraries (and what they need)
    fn foreign_flags(&mut self, p: usize) -> Result<Vec<String>, String> {
        if let Some(f) = self.foreign_cc.get(&p) {
            return Ok(f.clone());
        }
        let m = &self.g.pkgs[p].m;
        let mut flags = Vec::new();
        if !m.foreign.is_empty() {
            let base = self.target.join("foreign");
            let include = base.join("include");
            flags.push(format!("-I{}", include.display()));
            let mut needs: Vec<String> = Vec::new();
            for f in &m.foreign {
                let header = include.join(format!("{}.h", f.name));
                match &f.kind {
                    ForeignKind::Rust(dir) => {
                        write_if_changed(&header, &crate::foreign::rust_header(dir, &f.name))?;
                        status("Compiling", format!("{} (Rust, {})", f.name, dir.display()));
                        // cargo builds it as a static library (only what changed)
                        let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
                        c.args(["rustc", "--lib", "--crate-type", "staticlib", "--manifest-path"]).arg(dir.join("Cargo.toml")).arg("--target-dir").arg(base.join("cargo"));
                        if self.profile.optimize {
                            c.arg("--release");
                        }
                        c.args(["--", "--print", "native-static-libs"]);
                        crate::verbose(&c);
                        let o = c.output().map_err(|e| format!("can't run cargo for {}: {e}", f.name))?;
                        let err = String::from_utf8_lossy(&o.stderr);
                        if !o.status.success() {
                            return Err(format!("cargo couldn't build {} ({}):\n{err}", f.name, dir.display()));
                        }
                        // the system libraries the Rust library needs, as rustc says
                        for line in err.lines() {
                            if let Some(libs) = line.split("native-static-libs:").nth(1) {
                                for l in libs.split_whitespace() {
                                    if !needs.iter().any(|x| x == l) {
                                        needs.push(l.to_string());
                                    }
                                }
                            }
                        }
                        let lib = base.join("cargo").join(if self.profile.optimize { "release" } else { "debug" }).join(format!("lib{}.a", crate_lib_name(dir)?));
                        flags.push(lib.display().to_string());
                    }
                    ForeignKind::Zig(file) => {
                        write_if_changed(&header, &crate::foreign::zig_header(file, &f.name))?;
                        // rebuilt when a .zig file next to it changes; compiler_rt goes in with it
                        let out = base.join(format!("lib{}.a", f.name));
                        let mut inputs = Vec::new();
                        if let Some(d) = file.parent() {
                            zig_files(d, &mut inputs);
                        }
                        let mode = if self.profile.optimize { "ReleaseSafe" } else { "Debug" };
                        let args = vec!["build-lib".to_string(), file.display().to_string(), "-O".into(), mode.into(), "-fPIC".into(), "-fcompiler-rt".into(), format!("-femit-bin={}", out.display())];
                        let zig = PathBuf::from(std::env::var("ZIG").unwrap_or_else(|_| "zig".into()));
                        self.run_job(Job { out: out.clone(), inputs, args, what: format!("{} (Zig, {})", f.name, file.display()), program: Some(zig) })?;
                        flags.push(out.display().to_string());
                    }
                }
            }
            flags.extend(needs);
        }
        self.foreign_cc.insert(p, flags.clone());
        Ok(flags)
    }

    /// the libraries for other languages package p asks for ([lib] kind = shared, static) and their
    /// bindings: target/<profile>/libNAME.so, libNAME.a and bindings/NAME.{h,hpp,rs,zig,py,...},
    /// then what makes the bindings usable as they are (binding_extras)
    pub fn foreign(&self, p: usize) -> Result<(), String> {
        let m = &self.g.pkgs[p].m;
        if m.lib.is_none() || (m.bindings.is_empty() && !m.lib_kinds.iter().any(|k| k != "volt")) {
            return Ok(());
        }
        let closure = self.closure(p, false);
        let mut inputs: Vec<PathBuf> = self.std_inputs.clone();
        for q in &closure {
            inputs.extend(self.inputs.get(q).cloned().unwrap_or_else(|| volt_files(self.g.pkgs[*q].m.lib.as_ref().unwrap())));
        }
        let mut jobs = Vec::new();
        for kind in m.lib_kinds.iter().filter(|k| *k != "volt") {
            let out = self.target.join(format!("lib{}.{}", m.name, if kind == "shared" { "so" } else { "a" }));
            let mut args = self.args("lib");
            if let Some(b) = &self.backend {
                args.extend(["--backend".into(), b.clone()]);
            }
            args.push(m.name.clone());
            args.extend(self.pkg_args(&closure, None, false));
            args.extend([format!("--{kind}"), "-o".into(), out.display().to_string()]);
            jobs.push(Job { out, inputs: inputs.clone(), args, what: format!("{} v{} ({kind} library)", m.name, m.version.text), program: None });
        }
        // Swift and Kotlin/Native read the C header
        let mut langs: Vec<&str> = m.bindings.iter().map(|l| l.as_str()).collect();
        if !langs.contains(&"c") && langs.iter().any(|l| *l == "swift" || *l == "kotlin") {
            langs.push("c");
        }
        for lang in langs {
            let file = match lang {
                "c" => format!("{}.h", m.name),
                "cpp" => format!("{}.hpp", m.name),
                "rust" => format!("{}.rs", m.name),
                "python" => format!("{}.py", m.name),
                "pyi" => format!("{}.pyi", m.name),
                "csharp" => format!("{}.cs", m.name),
                "java" => format!("{}.java", m.name),
                "go" => format!("{}.go", m.name),
                "lua" => format!("{}_lua.c", m.name),
                "dart" => format!("{}.dart", m.name),
                "swift" => format!("{}.swift", m.name),
                "kotlin" => format!("{}.kt", m.name),
                "ruby" => format!("{}_ruby.c", m.name),
                "node" => format!("{}_node.c", m.name),
                "js" => format!("{}.js", m.name),
                "ts" => format!("{}.d.ts", m.name),
                "json" => format!("{}.json", m.name),
                _ => format!("{}.zig", m.name),
            };
            let out = self.target.join("bindings").join(file);
            let mut args = self.args("bindings");
            args.push(m.name.clone());
            args.extend(self.pkg_args(&closure, None, false));
            args.extend(["--lang".into(), lang.to_string(), "-o".into(), out.display().to_string()]);
            jobs.push(Job { out, inputs: inputs.clone(), args, what: format!("{} v{} ({lang} bindings)", m.name, m.version.text), program: None });
        }
        parallel(self.jobs, jobs, |j| self.run_job(j))?;
        self.binding_extras(p)
    }

    /// what makes package p's bindings usable as they are: the Node, Lua and Ruby modules, compiled
    /// against the shared library (bindings/NAME.node, which NAME.js loads; bindings/lua/NAME.so;
    /// bindings/ruby/NAME.so), the module map Swift imports the C header through
    /// (bindings/CNAME/module.modulemap) and Kotlin/Native's cinterop definition (bindings/NAME.def).
    /// A module whose headers aren't installed is a warning: its C file is there to build later
    fn binding_extras(&self, p: usize) -> Result<(), String> {
        let m = &self.g.pkgs[p].m;
        let name = &m.name;
        let dir = self.target.join("bindings");
        let mut jobs = Vec::new();
        for lang in &m.bindings {
            match lang.as_str() {
                "swift" => write_if_changed(&dir.join(format!("C{name}/module.modulemap")), &format!("module C{name} {{\n    header \"../{name}.h\"\n    export *\n}}\n"))?,
                "kotlin" => write_if_changed(&dir.join(format!("{name}.def")), &format!("headers = {name}.h\npackage = c{name}\ncompilerOpts = -I{}\nlinkerOpts = -L{} -l{name}\n", dir.display(), self.target.display()))?,
                "node" | "lua" | "ruby" => {
                    if !m.lib_kinds.iter().any(|k| k == "shared") {
                        crate::warn(format!("{name}: the {lang} module is built against the shared library ([lib] kind \"shared\"): only {name}_{lang}.c is written"));
                        continue;
                    }
                    let Some(includes) = module_includes(lang) else {
                        crate::warn(format!("{name}: {lang}'s headers aren't installed: {name}_{lang}.c isn't built"));
                        continue;
                    };
                    // the module, and the way back from it to libNAME.so in target/<profile>
                    let (out, up) = if lang == "node" { (dir.join(format!("{name}.node")), "..") } else { (dir.join(lang).join(format!("{name}.so")), "../..") };
                    let src = dir.join(format!("{name}_{lang}.c"));
                    let mut args = vec!["-shared".to_string(), "-fPIC".into()];
                    for i in includes {
                        args.extend(["-I".into(), i]);
                    }
                    args.extend([src.display().to_string(), "-L".into(), self.target.display().to_string(), format!("-l{name}")]);
                    if cfg!(target_os = "macos") {
                        args.extend(["-undefined".into(), "dynamic_lookup".into(), format!("-Wl,-rpath,@loader_path/{up}")]);
                    } else {
                        args.push(format!("-Wl,-rpath,$ORIGIN/{up}"));
                    }
                    args.extend(["-o".into(), out.display().to_string()]);
                    let lib = self.target.join(format!("lib{name}.so"));
                    jobs.push(Job { out, inputs: vec![src, lib], args, what: format!("{} v{} ({lang} module)", m.name, m.version.text), program: Some(c_compiler().into()) });
                }
                _ => {}
            }
        }
        parallel(self.jobs, jobs, |j| self.run_job(j))
    }

    /// type-check a package's library, or an executable, without building anything
    pub fn check(&self, pkg: usize, exe: Option<&Exe>) -> Result<(), String> {
        let m = &self.g.pkgs[pkg].m;
        let mut args = self.args("check");
        let what = match exe {
            Some(e) => {
                args.extend(e.roots.iter().flat_map(|r| volt_files(r)).map(|f| f.display().to_string()));
                args.extend(self.pkg_args(&self.closure(pkg, e.kind != Kind::Bin), Some(pkg), false));
                format!("{} v{} ({} \"{}\")", m.name, m.version.text, e.kind.name(), e.name)
            }
            None => {
                args.extend(["--lib".into(), m.name.clone()]);
                args.extend(self.pkg_args(&self.closure(pkg, false), None, false));
                format!("{} v{} ({})", m.name, m.version.text, m.dir.display())
            }
        };
        status("Checking", &what);
        let mut c = Command::new(&self.voltc);
        c.args(args);
        run_checked(c, &format!("checking {what}"))
    }

    /// the "Finished" line
    pub fn finished(&self, start: Instant) {
        let p = &self.profile;
        status("Finished", format!("`{}` profile [{}] target(s) in {:.2}s", p.name, if p.optimize { "optimized" } else { "unoptimized" }, start.elapsed().as_secs_f64()));
    }

    // ---------- build files ----------

    /// run package p's build files; their printed directives make its plan
    pub fn plan(&self, p: usize, defines: &[String]) -> Result<Plan, String> {
        let m = &self.g.pkgs[p].m;
        let mut plan = Plan::default();
        if m.build_files.is_empty() {
            return Ok(plan);
        }
        let api = api_dir();
        let dir = self.target.join("build").join(&m.name);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        for f in &m.build_files {
            let stem = f.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or("build".into());
            let exe = dir.join(&stem);
            let mut inputs = vec![f.clone(), self.voltc.clone()];
            inputs.extend(volt_files(&api));
            // the build's std, like everything else it compiles (not optimized: it runs once)
            let mut args: Vec<String> = self.args("build").into_iter().filter(|a| a != "--release").collect();
            args.extend([f.display().to_string(), "--pkg".into(), format!("bolt={}", api.display()), "-o".into(), exe.display().to_string()]);
            self.run_job(Job { out: exe.clone(), inputs, args, what: format!("build file {}", f.display()), program: None })?;
            let mut c = Command::new(&exe);
            c.args(defines).current_dir(&m.dir).env("BOLT_PROFILE", &self.profile.name).env("BOLT_PACKAGE", &m.name);
            for feat in &self.act.features[p] {
                c.env(format!("BOLT_FEATURE_{}", feat.to_uppercase().replace('-', "_")), "1");
            }
            crate::verbose(&c);
            let out = c.output().map_err(|e| format!("can't run {}: {e}", f.display()))?;
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                match line.strip_prefix("@bolt\t") {
                    Some(d) => plan.directive(d, &m.dir).map_err(|e| format!("{}: {e}", f.display()))?,
                    None => println!("{line}"),
                }
            }
            eprint!("{}", String::from_utf8_lossy(&out.stderr));
            if !out.status.success() {
                return Err(format!("build file {} failed", f.display()));
            }
        }
        Ok(plan)
    }

    /// every executable of package p a plain `bolt build` makes: its [[bin]]s and its build files' exes
    pub fn install_exes(&self, p: usize, plan: &Plan) -> Vec<Exe> {
        let m = &self.g.pkgs[p].m;
        let mut v: Vec<Exe> = m.of(Kind::Bin).filter(|t| self.has_features(p, t)).map(|t| self.exe_of(p, t)).collect();
        v.extend(plan.exes.iter().map(|(n, roots)| Exe { pkg: p, kind: Kind::Bin, name: n.clone(), roots: roots.clone(), out: self.exe_path(Kind::Bin, n) }));
        v
    }

    /// are target t's required features on?
    pub fn has_features(&self, p: usize, t: &Target) -> bool {
        t.required_features.iter().all(|f| self.act.features[p].contains(f))
    }

    /// runs step `name` of package p after its dependencies; "install" builds every executable
    pub fn run_step(&mut self, p: usize, name: &str, plan: &Plan) -> Result<(), String> {
        let mut built: Option<Vec<Exe>> = None;
        self.step_in(p, name, plan, &mut Vec::new(), &mut built, &mut Vec::new())
    }

    /// run_step, with `done` the steps already run and `path` the chain being entered (to report a cycle)
    fn step_in(&mut self, p: usize, name: &str, plan: &Plan, done: &mut Vec<String>, built: &mut Option<Vec<Exe>>, path: &mut Vec<String>) -> Result<(), String> {
        if path.iter().any(|s| s == name) {
            return Err(format!("steps depend on each other: {} -> {name}", path.join(" -> ")));
        }
        if done.iter().any(|d| d == name) {
            return Ok(());
        }
        done.push(name.to_string());
        if name == "install" {
            let exes = self.install_exes(p, plan);
            self.libraries(&self.closure(p, false))?;
            self.executables(&exes, &HashMap::from([(p, plan.clone())]))?;
            *built = Some(exes);
            return Ok(());
        }
        let Some(step) = plan.steps.get(name) else {
            let known: Vec<&str> = ["install"].into_iter().chain(plan.steps.keys().map(|k| k.as_str())).collect();
            return Err(format!("no step '{name}' (steps: {})", known.join(", ")));
        };
        path.push(name.to_string());
        for d in &step.deps {
            self.step_in(p, d, plan, done, built, path)?;
        }
        path.pop();
        let dir = self.g.pkgs[p].m.dir.clone();
        for a in &step.actions {
            let mut c = match a {
                Action::Cmd(argv) => {
                    let mut c = Command::new(&argv[0]);
                    c.args(&argv[1..]);
                    c
                }
                Action::Run(exe, args) => {
                    if built.is_none() {
                        self.step_in(p, "install", plan, done, built, &mut Vec::new())?;
                    }
                    let path = built.as_ref().unwrap().iter().find(|b| &b.name == exe).map(|b| b.out.clone()).ok_or(format!("step {name}: no executable '{exe}'"))?;
                    let mut c = Command::new(path);
                    c.args(args);
                    c
                }
            };
            c.current_dir(&dir);
            // what the package's executables were linked with, for steps that build more (one per line)
            let cc: Vec<&str> = self.profile.cc_flags.iter().chain(&plan.cc).map(String::as_str).collect();
            c.env("BOLT_CC_ARGS", cc.join("\n"));
            status("Running", format!("step {name}"));
            run_checked(c, &format!("step {name}"))?;
        }
        Ok(())
    }

    // ---------- tests and benchmarks ----------

    /// run built test (or bench) executables in their package's directory: pass = exit 0
    pub fn run_tests(&self, exes: &[Exe], bench: bool) -> bool {
        let start = Instant::now();
        let (mut passed, mut failed) = (0, 0);
        for e in exes {
            let dir = &self.g.pkgs[e.pkg].m.dir;
            status("Running", format!("{}/{} ({})", e.kind.dir(), e.name, rel(&e.out)));
            let t = Instant::now();
            let out = Command::new(&e.out).current_dir(dir).output().unwrap_or_else(|err| fail(format!("can't run {}: {err}", e.out.display())));
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            if out.status.success() {
                passed += 1;
                if bench {
                    println!("bench {} ... {ms:.3} ms", e.name);
                } else {
                    println!("test {} ... ok", e.name);
                }
            } else {
                failed += 1;
                let why = out.status.code().map_or("killed by a signal".to_string(), |c| format!("exit code {c}"));
                println!("{} {} ... FAILED ({why})\n{}{}", if bench { "bench" } else { "test" }, e.name, String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
            }
        }
        let verdict = if failed == 0 { "ok" } else { "FAILED" };
        println!("\n{} result: {verdict}. {passed} passed; {failed} failed; finished in {:.2}s", if bench { "bench" } else { "test" }, start.elapsed().as_secs_f64());
        failed == 0
    }
}

/// a path as short as possible: relative to the current directory when it's inside it
pub fn rel(p: &Path) -> String {
    let cwd = std::env::current_dir().unwrap_or_default();
    p.strip_prefix(&cwd).unwrap_or(p).display().to_string()
}

/// the features each selected package is asked for: --features FEATURE goes to the selected
/// packages that have it, PACKAGE/FEATURE to that selected package, DEPENDENCY/FEATURE to the ones
/// that depend on it
fn wants(g: &Graph, roots: &[usize], o: &Opts, dev: bool) -> Result<Vec<Want>, String> {
    let mut ws: Vec<Want> = roots.iter().map(|&pkg| Want { pkg, features: Vec::new(), all: o.all_features, no_default: o.no_default_features }).collect();
    for f in &o.features {
        let targets: Vec<usize> = match f.split_once('/') {
            Some((p, feat)) if roots.iter().any(|r| g.pkgs[*r].m.name == p) => {
                let i = roots.iter().position(|r| g.pkgs[*r].m.name == p).unwrap();
                ws[i].features.push(feat.to_string());
                continue;
            }
            Some((d, _)) => {
                let d = d.trim_end_matches('?');
                (0..roots.len()).filter(|i| g.pkgs[roots[*i]].m.dep(d, false).is_some() || (dev && g.pkgs[roots[*i]].m.dep(d, true).is_some())).collect()
            }
            None => (0..roots.len()).filter(|i| g.pkgs[roots[*i]].m.features.contains_key(f)).collect(),
        };
        if targets.is_empty() {
            let first = &g.pkgs[roots[0]].m.name;
            return Err(match f.split_once('/') {
                Some((d, _)) => format!("package {first} has no dependency '{d}'"),
                None => format!("package {first} has no feature '{f}'"),
            });
        }
        for i in targets {
            ws[i].features.push(f.clone());
        }
    }
    Ok(ws)
}

/// the bolt build API package (Volt sources), for build files
fn api_dir() -> PathBuf {
    if let Some(p) = std::env::var_os("BOLT_API") {
        return p.into();
    }
    let exe = std::env::current_exe().unwrap_or_else(|e| fail(e));
    let dir = exe.parent().unwrap();
    for cand in [dir.join("api"), dir.join("../../bolt/api"), dir.join("../lib/volt/bolt")] {
        if cand.is_dir() {
            return cand;
        }
    }
    fail("can't find the bolt build API; set BOLT_API")
}

// ---------- build-file plans ----------

/// what a step does: run a program (argv), or one of the package's executables with arguments
#[derive(Clone)]
pub enum Action {
    Cmd(Vec<String>),
    Run(String, Vec<String>),
}

/// a named step from the build files: its actions, and the steps that run first
#[derive(Default, Clone)]
pub struct Step {
    actions: Vec<Action>,
    deps: Vec<String>,
}

/// what the build files asked for: extra executables (name, source paths), sources and C inputs added
/// to every executable, and named steps
#[derive(Default, Clone)]
pub struct Plan {
    pub exes: Vec<(String, Vec<PathBuf>)>,
    pub sources: Vec<PathBuf>,
    pub cc: Vec<String>,
    pub steps: BTreeMap<String, Step>,
}

impl Plan {
    /// one `@bolt` line from a build file: the command, then tab-separated arguments
    fn directive(&mut self, line: &str, dir: &Path) -> Result<(), String> {
        let parts: Vec<&str> = line.split('\t').collect();
        let (cmd, args) = parts.split_first().unwrap();
        let need = |n: usize| if args.len() < n { Err(format!("@bolt {cmd} needs {n} arguments")) } else { Ok(()) };
        let step = |p: &mut Plan, n: &str| -> Result<(), String> {
            if p.steps.contains_key(n) { Ok(()) } else { Err(format!("no step '{n}' (declare it with bolt::step first)")) }
        };
        match *cmd {
            "exe" => {
                need(2)?;
                self.exes.push((args[0].to_string(), args[1..].iter().map(|a| dir.join(a)).collect()));
            }
            "source" => {
                need(1)?;
                self.sources.push(dir.join(args[0]));
            }
            "c_source" => {
                need(1)?;
                self.cc.push(dir.join(args[0]).to_string_lossy().to_string());
            }
            "link_c" => {
                need(1)?;
                self.cc.push(format!("-l{}", args[0]));
            }
            "cc_arg" => {
                need(1)?;
                self.cc.push(args[0].to_string());
            }
            "step" => {
                need(1)?;
                self.steps.entry(args[0].to_string()).or_default();
            }
            "cmd" => {
                need(2)?;
                step(self, args[0])?;
                self.steps.get_mut(args[0]).unwrap().actions.push(Action::Cmd(args[1..].iter().map(|s| s.to_string()).collect()));
            }
            "run" => {
                need(2)?;
                step(self, args[0])?;
                let a = Action::Run(args[1].to_string(), args[2..].iter().map(|s| s.to_string()).collect());
                self.steps.get_mut(args[0]).unwrap().actions.push(a);
            }
            "depends" => {
                need(2)?;
                step(self, args[0])?;
                self.steps.get_mut(args[0]).unwrap().deps.push(args[1].to_string());
            }
            other => return Err(format!("unknown @bolt directive '{other}'")),
        }
        Ok(())
    }
}
