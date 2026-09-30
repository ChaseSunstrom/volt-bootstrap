// Dependency resolution. First every package the workspace can reach (members, their
// dependencies and dev-dependencies, optional ones too), with git dependencies fetched into a
// cache and pinned in bolt.lock. Then, for one build, which of them are on and with which
// features, and the order their libraries build in.
use crate::manifest::{self, Dep, GitRef, Manifest, Source, Workspace};
use crate::toml::{self, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;

// ---------- git dependencies ----------

/// FNV-1a, for stable cache directory names
pub fn fnv64(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// where git dependencies are cached: $BOLT_HOME, else $XDG_CACHE_HOME/bolt, else ~/.cache/bolt
pub fn cache_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("BOLT_HOME") {
        return d.into();
    }
    if let Some(d) = std::env::var_os("XDG_CACHE_HOME") {
        return PathBuf::from(d).join("bolt");
    }
    let home = std::env::var_os("HOME").unwrap_or_else(|| crate::fail("HOME isn't set; set BOLT_HOME for the git cache"));
    PathBuf::from(home).join(".cache/bolt")
}

/// runs git; its trimmed stdout, or its stderr as the error
fn git(args: &[&str]) -> Result<String, String> {
    // urls come from dependencies' manifests: never let a transport run commands (ext::)
    let out = Command::new("git").args(["-c", "protocol.ext.allow=never"]).args(args).output().map_err(|e| format!("can't run git: {e}"))?;
    if !out.status.success() {
        return Err(format!("git {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// bolt.lock: the commit each git dependency (url and the rev, branch or tag asked for) is pinned to
#[derive(Default)]
pub struct Lock {
    git: BTreeMap<(String, String), String>,
    /// the entries this resolution used: the others are dropped when the lock is written
    used: BTreeSet<(String, String)>,
    changed: bool,
    /// --offline: never touch the network
    pub offline: bool,
}

impl Lock {
    /// bolt.lock in root (empty when there is none)
    pub fn read(root: &Path, offline: bool) -> Result<Lock, String> {
        let mut l = Lock { offline, ..Default::default() };
        let Ok(src) = std::fs::read_to_string(root.join("bolt.lock")) else { return Ok(l) };
        let t = toml::parse(&src).map_err(|_| "bolt.lock is damaged; delete it to resolve again")?;
        for e in t.get("git").and_then(Value::as_array).unwrap_or(&[]) {
            let e = e.as_table().ok_or("bolt.lock is damaged; delete it to resolve again")?;
            let s = |k: &str| e.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            l.git.insert((s("url"), s("rev")), s("commit"));
        }
        Ok(l)
    }

    /// forget the pins of these (url, spec) keys, so they resolve again (bolt update)
    pub fn unpin(&mut self, keys: &[(String, String)]) {
        for k in keys {
            self.git.remove(k);
        }
    }

    /// the pinned commit of a key
    pub fn pinned(&self, key: &(String, String)) -> Option<&String> {
        self.git.get(key)
    }

    /// rewrites bolt.lock when a pin was added or dropped; with --locked, that's an error instead
    pub fn write(&mut self, root: &Path, locked: bool) -> Result<(), String> {
        let before = self.git.len();
        let used = std::mem::take(&mut self.used);
        self.git.retain(|k, _| used.contains(k));
        if !self.changed && self.git.len() == before {
            return Ok(());
        }
        if locked {
            return Err("bolt.lock needs to change, but --locked (or --frozen) was given".into());
        }
        let mut out = String::from("# written by bolt: the exact commits of git dependencies\n");
        for ((url, rev), commit) in &self.git {
            out.push_str(&format!("\n[[git]]\nurl = {}\nrev = {}\ncommit = {}\n", toml::quote(url), toml::quote(rev), toml::quote(commit)));
        }
        std::fs::write(root.join("bolt.lock"), out).map_err(|e| format!("can't write bolt.lock: {e}"))
    }
}

/// a checkout of `url` at the locked commit (or what `at` names now, which is then pinned), and that commit
pub fn fetch(url: &str, at: &GitRef, lock: &mut Lock) -> Result<(PathBuf, String), String> {
    let spec = at.spec();
    // a manifest's url or rev must not turn into a git option (--upload-pack=...) or a range
    if url.starts_with('-') || spec.starts_with('-') || spec.contains("..") {
        return Err(format!("git dependency {url}: url and rev can't start with '-' or contain '..'"));
    }
    // readable and hashed: https://x/json.git -> json-<hash>
    let tail: String = url.trim_end_matches('/').trim_end_matches(".git").rsplit(['/', ':']).next().unwrap_or("").chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').take(40).collect();
    let key = format!("{tail}-{:016x}", fnv64(url));
    let db = cache_dir().join("git/db").join(&key);
    let dbs = db.to_string_lossy().to_string();
    let offline = |what: &str| format!("can't {what} {url}: --offline (or --frozen) was given");
    let update = |dbs: &str| {
        crate::status("Updating", format!("git repository `{url}`"));
        git(&["--git-dir", dbs, "fetch", "--quiet", "origin", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"])
    };
    let mut fresh = false;
    if !db.exists() {
        if lock.offline {
            return Err(offline("fetch"));
        }
        crate::status("Fetching", url);
        std::fs::create_dir_all(db.parent().unwrap()).map_err(|e| e.to_string())?;
        git(&["clone", "--quiet", "--bare", "--", url, &dbs])?;
        fresh = true;
    }
    let lk = (url.to_string(), spec.clone());
    lock.used.insert(lk.clone());
    let commit = match lock.git.get(&lk) {
        Some(c) => c.clone(),
        None => {
            // nothing pinned: a branch (or the default one) may have moved, a rev or tag hasn't
            if at.moves() && !fresh && !lock.offline {
                update(&dbs)?;
            }
            let want = if spec.is_empty() { "HEAD".to_string() } else { spec.clone() };
            let find = || git(&["--git-dir", &dbs, "rev-parse", "--verify", "--quiet", &format!("{want}^{{commit}}")]);
            let c = match find() {
                Ok(c) => c,
                Err(_) if lock.offline => return Err(offline("find the revision of")),
                Err(_) => {
                    update(&dbs)?;
                    find().map_err(|_| format!("{url} has no revision '{want}'"))?
                }
            };
            lock.git.insert(lk, c.clone());
            lock.changed = true;
            c
        }
    };
    // one worktree per commit, shared by every package that uses it
    let co = cache_dir().join("git/checkouts").join(format!("{key}-{}", &commit[..12.min(commit.len())]));
    if !co.exists() {
        if git(&["--git-dir", &dbs, "cat-file", "-e", &format!("{commit}^{{commit}}")]).is_err() {
            if lock.offline {
                return Err(offline(&format!("fetch commit {commit} of")));
            }
            update(&dbs)?;
        }
        git(&["--git-dir", &dbs, "worktree", "add", "--quiet", "--detach", &co.to_string_lossy(), &commit])?;
    }
    Ok((co, commit))
}

// ---------- the package graph ----------

/// one package the workspace can reach
pub struct Pkg {
    pub m: Manifest,
    /// how tree and metadata show where it's from: path+DIR, or git+URL#COMMIT
    pub source: String,
    /// for git packages: the bolt.lock key (bolt update)
    pub lock_key: Option<(String, String)>,
    pub member: bool,
}

pub struct Graph {
    pub pkgs: Vec<Pkg>,
    pub by_name: HashMap<String, usize>,
}

impl Graph {
    /// the package a dependency of `p` resolved to
    pub fn target(&self, d: &Dep) -> usize {
        self.by_name[&d.name]
    }
}

/// every package reachable from the members (their dev-dependencies too; a dependency's own
/// dev-dependencies aren't needed), each name meaning one directory
pub fn resolve(ws: Workspace, lock: &mut Lock) -> Result<Graph, String> {
    let mut g = Graph { pkgs: Vec::new(), by_name: HashMap::new() };
    for m in ws.members {
        g.by_name.insert(m.name.clone(), g.pkgs.len());
        g.pkgs.push(Pkg { source: format!("path+{}", m.dir.display()), m, lock_key: None, member: true });
    }
    let mut i = 0;
    while i < g.pkgs.len() {
        let member = g.pkgs[i].member;
        let mut found = Vec::new();
        for d in g.pkgs[i].m.deps.iter().filter(|d| member || !d.dev) {
            let (dir, source, lock_key) = match &d.source {
                Source::Path(p) => {
                    let dir = p.canonicalize().map_err(|e| format!("dependency {}: {}: {e}", d.name, p.display()))?;
                    let s = format!("path+{}", dir.display());
                    (dir, s, None)
                }
                Source::Git { url, at } => {
                    let (dir, commit) = fetch(url, at, lock)?;
                    (dir, format!("git+{url}#{commit}"), Some((url.clone(), at.spec())))
                }
            };
            found.push((d.name.clone(), dir, source, lock_key));
        }
        for (name, dir, source, lock_key) in found {
            if let Some(&j) = g.by_name.get(&name) {
                if g.pkgs[j].m.dir.canonicalize().ok() != Some(dir.clone()) {
                    return Err(format!("two different packages are both called '{name}' ({} and {})", g.pkgs[j].m.dir.display(), dir.display()));
                }
                continue;
            }
            let m = manifest::load(&dir)?;
            if m.name != name {
                return Err(format!("dependency '{name}' is a package called '{}' (use that name)", m.name));
            }
            if m.lib.is_none() {
                return Err(format!("dependency '{name}' has no library (no [lib] or lib/ directory)"));
            }
            g.by_name.insert(name, g.pkgs.len());
            g.pkgs.push(Pkg { m, source, lock_key, member: false });
        }
        i += 1;
    }
    // what each dependency asks of the version
    for p in &g.pkgs {
        for d in &p.m.deps {
            let t = &g.pkgs[g.target(d)].m;
            if let Some(r) = d.req.as_ref().filter(|r| !r.matches(&t.version)) {
                return Err(format!("{} needs {} {}, but {} is {}", p.m.name, d.name, r.text, t.dir.display(), t.version.text));
            }
        }
    }
    Ok(g)
}

// ---------- features ----------

/// what the command line asks of one selected package
pub struct Want {
    pub pkg: usize,
    /// --features: FEATURE or DEPENDENCY/FEATURE
    pub features: Vec<String>,
    pub all: bool,
    pub no_default: bool,
}

/// the packages one build uses and their features
pub struct Active {
    pub on: Vec<bool>,
    pub features: Vec<BTreeSet<String>>,
    /// the dependencies (by package) each package uses: normal ones, then dev ones for the selected
    pub deps: Vec<Vec<usize>>,
    pub dev_deps: Vec<Vec<usize>>,
}

impl Active {
    /// the libraries `pkg`'s code can use: its own, its dependencies' and theirs (and, with dev, its
    /// dev-dependencies'), in build order
    pub fn closure(&self, g: &Graph, pkg: usize, dev: bool, order: &[usize]) -> Vec<usize> {
        let mut seen = vec![false; g.pkgs.len()];
        let mut todo = vec![pkg];
        if dev {
            todo.extend(&self.dev_deps[pkg]);
        }
        while let Some(p) = todo.pop() {
            if !std::mem::replace(&mut seen[p], true) {
                todo.extend(&self.deps[p]);
            }
        }
        order.iter().copied().filter(|p| seen[*p]).collect()
    }
}

/// turns on the selected packages, their dependencies and the features asked for (unified: one
/// set per package for the whole build); `dev` adds the selected packages' dev-dependencies
pub fn activate(g: &Graph, wants: &[Want], dev: bool) -> Result<Active, String> {
    struct A<'g> {
        g: &'g Graph,
        act: Active,
        edges: BTreeSet<(usize, String, bool)>,
        /// DEPENDENCY?/FEATURE: only once something else turns the dependency on
        weak: Vec<(usize, String, String)>,
        dev_roots: Vec<usize>,
    }
    impl A<'_> {
        fn include(&mut self, p: usize) -> Result<(), String> {
            if std::mem::replace(&mut self.act.on[p], true) {
                return Ok(());
            }
            let m = &self.g.pkgs[p].m;
            let dev = self.dev_roots.contains(&p);
            let names: Vec<(String, bool)> = m.deps.iter().filter(|d| !d.optional && (!d.dev || dev)).map(|d| (d.name.clone(), d.dev)).collect();
            for (n, d) in names {
                self.edge(p, &n, d)?;
            }
            Ok(())
        }
        /// p uses its dependency `name`: turn it on with the features p asks for
        fn edge(&mut self, p: usize, name: &str, dev: bool) -> Result<(), String> {
            if !self.edges.insert((p, name.to_string(), dev)) {
                return Ok(());
            }
            let g = self.g;
            let d = g.pkgs[p].m.dep(name, dev).ok_or(format!("package {} has no dependency '{name}'", g.pkgs[p].m.name))?;
            let t = g.target(d);
            if dev { &mut self.act.dev_deps[p] } else { &mut self.act.deps[p] }.push(t);
            self.include(t)?;
            if d.default_features && g.pkgs[t].m.features.contains_key("default") {
                self.enable(t, "default")?;
            }
            for f in &d.features {
                self.item(t, f)?;
            }
            Ok(())
        }
        fn enable(&mut self, p: usize, f: &str) -> Result<(), String> {
            let g = self.g;
            let list = g.pkgs[p].m.features.get(f).ok_or(format!("package {} has no feature '{f}'", g.pkgs[p].m.name))?;
            if !self.act.features[p].insert(f.to_string()) {
                return Ok(());
            }
            for it in list {
                self.item(p, it)?;
            }
            Ok(())
        }
        /// one thing a feature (or --features) turns on in p
        fn item(&mut self, p: usize, it: &str) -> Result<(), String> {
            if let Some(d) = it.strip_prefix("dep:") {
                return self.edge(p, d, false);
            }
            match it.split_once('/') {
                Some((d, f)) if d.ends_with('?') => {
                    self.weak.push((p, d.trim_end_matches('?').to_string(), f.to_string()));
                    Ok(())
                }
                Some((d, f)) => {
                    // a dev-dependency's feature (from --features, in a build that uses dev-dependencies)
                    let dev = self.g.pkgs[p].m.dep(d, false).is_none() && self.dev_roots.contains(&p);
                    self.edge(p, d, dev)?;
                    let t = self.g.by_name[d];
                    self.enable(t, f)
                }
                None => self.enable(p, it),
            }
        }
    }
    let n = g.pkgs.len();
    let mut a = A {
        g,
        act: Active { on: vec![false; n], features: vec![BTreeSet::new(); n], deps: vec![Vec::new(); n], dev_deps: vec![Vec::new(); n] },
        edges: BTreeSet::new(),
        weak: Vec::new(),
        dev_roots: if dev { wants.iter().map(|w| w.pkg).collect() } else { Vec::new() },
    };
    for w in wants {
        a.include(w.pkg)?;
        let m = &g.pkgs[w.pkg].m;
        if !w.no_default && m.features.contains_key("default") {
            a.enable(w.pkg, "default")?;
        }
        if w.all {
            for f in m.features.keys() {
                a.enable(w.pkg, f)?;
            }
        }
        for f in &w.features {
            a.item(w.pkg, f)?;
        }
    }
    // weak features apply once their dependency is on, which can turn on more
    loop {
        let ready: Vec<(usize, String, String)> = a.weak.iter().filter(|(p, d, _)| a.edges.contains(&(*p, d.clone(), false))).cloned().collect();
        let before: usize = a.act.features.iter().map(BTreeSet::len).sum();
        for (_, d, f) in ready {
            let t = g.by_name[&d];
            a.enable(t, &f)?;
        }
        if a.act.features.iter().map(BTreeSet::len).sum::<usize>() == before {
            break;
        }
    }
    Ok(a.act)
}

/// the packages that are on, each after the ones it depends on (dev-dependencies don't count:
/// they're for executables); an error names a dependency cycle
pub fn build_order(g: &Graph, act: &Active) -> Result<Vec<usize>, String> {
    fn visit(p: usize, g: &Graph, act: &Active, state: &mut [u8], stack: &mut Vec<usize>, out: &mut Vec<usize>) -> Result<(), String> {
        match state[p] {
            2 => return Ok(()),
            1 => {
                let from = stack.iter().position(|q| *q == p).unwrap();
                let names: Vec<&str> = stack[from..].iter().chain([&p]).map(|q| g.pkgs[*q].m.name.as_str()).collect();
                return Err(format!("dependency cycle: {}", names.join(" -> ")));
            }
            _ => {}
        }
        state[p] = 1;
        stack.push(p);
        for &d in &act.deps[p] {
            visit(d, g, act, state, stack, out)?;
        }
        stack.pop();
        state[p] = 2;
        out.push(p);
        Ok(())
    }
    let mut state = vec![0u8; g.pkgs.len()];
    let mut out = Vec::new();
    for p in (0..g.pkgs.len()).filter(|p| act.on[*p]) {
        visit(p, g, act, &mut state, &mut Vec::new(), &mut out)?;
    }
    Ok(out)
}
