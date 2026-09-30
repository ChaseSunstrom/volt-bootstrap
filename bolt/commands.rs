// The commands that manage packages rather than build them: new and init, add and remove (which
// edit bolt.toml as text, so comments and layout stay), update and fetch, tree, metadata, and
// install and uninstall.
use crate::build::Build;
use crate::manifest::{self, GitRef};
use crate::resolve::{self, Lock};
use crate::toml::{self, Value};
use crate::{Opts, OrFail, fail, status, warn};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

// ---------- new, init ----------

/// `bolt new PATH` / `bolt init [PATH]`: a package with a hello-world src/main.volt (or, with --lib,
/// a library in lib/), a .gitignore, and a git repository unless it's already in one
pub fn new_package(o: &Opts, init: bool) {
    let dir = match (o.words.first(), init) {
        (Some(p), _) => PathBuf::from(p),
        (None, true) => std::env::current_dir().or_fail(),
        (None, false) => fail("bolt new PATH: where to make the package"),
    };
    if !init && dir.exists() {
        fail(format!("{} already exists (bolt init makes a package in an existing directory)", dir.display()));
    }
    if dir.join("bolt.toml").exists() {
        fail(format!("{} already has a bolt.toml", dir.display()));
    }
    let base = dir.canonicalize().unwrap_or(dir.clone()).file_name().map(|n| n.to_string_lossy().to_lowercase().replace('-', "_")).unwrap_or_default();
    let name = o.name.clone().unwrap_or(base);
    if !manifest::ident(&name) {
        fail(format!("'{name}' can't be a package name: use lowercase letters, digits and _ (it becomes a namespace); pick one with --name NAME"));
    }
    let mut files = vec![("bolt.toml".to_string(), format!("[package]\nname = \"{name}\"\nversion = \"0.1.0\"\n"))];
    if o.lib {
        files.push((format!("lib/{name}.volt"), "// a function other packages can call as NAME::add\nfn add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n".replace("NAME", &name)));
    } else {
        files.push(("src/main.volt".into(), format!("use std::io;\n\nfn main() -> void {{\n    std::println(\"hello from {name}\");\n}}\n")));
    }
    for (f, text) in files {
        let p = dir.join(&f);
        if !p.exists() {
            std::fs::create_dir_all(p.parent().unwrap()).or_fail();
            std::fs::write(&p, text).or_fail();
        }
    }
    let ignore = dir.join(".gitignore");
    let old = std::fs::read_to_string(&ignore).unwrap_or_default();
    if !old.lines().any(|l| l.trim() == "/target") {
        std::fs::write(&ignore, format!("{old}/target\n")).or_fail();
    }
    // like cargo: a new repository, unless --vcs none or this is inside one already
    let inside = Command::new("git").args(["rev-parse", "--is-inside-work-tree"]).current_dir(&dir).output().is_ok_and(|o| o.status.success());
    if o.vcs.as_deref() != Some("none") && !inside {
        let _ = Command::new("git").args(["init", "-q"]).current_dir(&dir).status();
    }
    status("Created", format!("{} package `{name}`", if o.lib { "library" } else { "binary (application)" }));
}

// ---------- add, remove ----------

/// the member of the workspace here that -p names (or the only one meant)
fn member_dir(o: &Opts) -> PathBuf {
    let ws = manifest::workspace(o.manifest_path.as_deref()).or_fail();
    let i = match o.packages.as_slice() {
        [p] => ws.members.iter().position(|m| m.name == *p).unwrap_or_else(|| fail(format!("no package '{p}' in this workspace"))),
        [] if ws.default.len() == 1 => ws.default[0],
        _ => fail("pick the package to change with -p NAME"),
    };
    ws.members[i].dir.clone()
}

/// the line index range of `name`'s entry in [section] (an inline table can span lines when its arrays do)
fn find_entry(lines: &[&str], section: &str, name: &str) -> Option<(usize, usize, usize)> {
    let h = lines.iter().position(|l| l.trim() == format!("[{section}]"))?;
    let end = (h + 1..lines.len()).find(|i| lines[*i].trim_start().starts_with('[')).unwrap_or(lines.len());
    let key = |l: &str| l.split('=').next().map(|k| k.trim().trim_matches('"').to_string());
    let i = (h + 1..end).find(|i| !lines[*i].trim_start().starts_with('#') && lines[*i].contains('=') && key(lines[*i]).as_deref() == Some(name))?;
    // the entry ends where its brackets close (strings and comments don't count)
    let mut depth = 0i32;
    let mut n = end - i;
    'lines: for (k, l) in lines[i..end].iter().enumerate() {
        let mut in_str = false;
        for c in l.chars() {
            match c {
                '"' | '\'' => in_str = !in_str,
                '#' if !in_str => break,
                '[' | '{' if !in_str => depth += 1,
                ']' | '}' if !in_str => depth -= 1,
                _ => {}
            }
        }
        if depth <= 0 {
            n = k + 1;
            break 'lines;
        }
    }
    Some((h, i, n))
}

/// text with `name`'s entry in [section] replaced by `line` (added at the section's end, or with a
/// new section, when it isn't there), or removed when line is None
fn set_entry(text: &str, section: &str, name: &str, line: Option<&str>) -> Result<String, String> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.iter().any(|l| l.trim() == format!("[{section}.{name}]")) {
        return Err(format!("{name} is written as a [{section}.{name}] table: edit it in bolt.toml"));
    }
    let mut out: Vec<String> = lines.iter().map(|s| s.to_string()).collect();
    match (find_entry(&lines, section, name), line) {
        (Some((_, i, n)), Some(l)) => {
            out.splice(i..i + n, [l.to_string()]);
        }
        (Some((_, i, n)), None) => {
            out.drain(i..i + n);
        }
        (None, None) => return Err(format!("no dependency '{name}' in [{section}]")),
        (None, Some(l)) => match lines.iter().position(|x| x.trim() == format!("[{section}]")) {
            Some(h) => {
                let end = (h + 1..lines.len()).find(|i| lines[*i].trim_start().starts_with('[')).unwrap_or(lines.len());
                let last = (h + 1..end).rev().find(|i| !lines[*i].trim().is_empty() && !lines[*i].trim_start().starts_with('#')).unwrap_or(h);
                out.insert(last + 1, l.to_string());
            }
            None => {
                if out.last().is_some_and(|l| !l.trim().is_empty()) {
                    out.push(String::new());
                }
                out.push(format!("[{section}]"));
                out.push(l.to_string());
            }
        },
    }
    Ok(out.join("\n") + "\n")
}

/// `bolt add [NAME[@REQ]] (--path DIR | --git URL [--rev R | --branch B | --tag T])`
pub fn add(o: &Opts) {
    let dir = member_dir(o);
    let file = dir.join("bolt.toml");
    let text = std::fs::read_to_string(&file).or_fail();
    let (given, req) = match o.words.first().map(|w| w.split_once('@').map_or((w.clone(), None), |(n, r)| (n.to_string(), Some(r.to_string())))) {
        Some((n, r)) => (Some(n), r),
        None => (None, None),
    };
    let mut parts = Vec::new();
    // what the entry names, and where that package is now (to check it)
    let (pkg_dir, shown) = if let Some(p) = &o.path {
        let here = std::env::current_dir().or_fail();
        let target = here.join(p);
        // as typed when bolt runs in the package's directory, else absolute
        let stored = if here.canonicalize().ok() == dir.canonicalize().ok() { p.clone() } else { target.canonicalize().unwrap_or(target.clone()).display().to_string() };
        parts.push(format!("path = {}", toml::quote(&stored)));
        (target, format!("path {stored}"))
    } else if let Some(url) = &o.git {
        parts.push(format!("git = {}", toml::quote(url)));
        let at = match (&o.rev, &o.branch, &o.tag) {
            (Some(r), None, None) => GitRef::Rev(r.clone()),
            (None, Some(b), None) => GitRef::Branch(b.clone()),
            (None, None, Some(t)) => GitRef::Tag(t.clone()),
            (None, None, None) => GitRef::Default,
            _ => fail("give at most one of --rev, --branch and --tag"),
        };
        for (k, v) in [("rev", &o.rev), ("branch", &o.branch), ("tag", &o.tag)] {
            if let Some(v) = v {
                parts.push(format!("{k} = {}", toml::quote(v)));
            }
        }
        let mut lock = Lock::read(&dir, o.offline).or_fail();
        let (co, _) = {
            let _cache = crate::build::lock_file(&resolve::cache_dir().join("lock"));
            resolve::fetch(url, &at, &mut lock).or_fail()
        };
        (co, format!("git {url}"))
    } else {
        fail("bolt has no registry: add a dependency with --path DIR or --git URL")
    };
    let dep = manifest::load(&pkg_dir).or_fail();
    let name = given.unwrap_or(dep.name.clone());
    if dep.name != name {
        fail(format!("the package at {} is called '{}', not '{name}'", pkg_dir.display(), dep.name));
    }
    if dep.lib.is_none() {
        fail(format!("{name} has no library (no [lib] or lib/ directory) to depend on"));
    }
    if let Some(r) = &req {
        let rq = manifest::req(r).or_fail();
        if !rq.matches(&dep.version) {
            fail(format!("{name} is version {}, which doesn't match {r}", dep.version.text));
        }
        parts.push(format!("version = {}", toml::quote(r)));
    }
    if o.optional {
        parts.push("optional = true".into());
    }
    if o.no_default_features {
        parts.push("default-features = false".into());
    }
    if !o.features.is_empty() {
        parts.push(format!("features = [{}]", o.features.iter().map(|f| toml::quote(f)).collect::<Vec<_>>().join(", ")));
    }
    let section = if o.dev { "dev-dependencies" } else { "dependencies" };
    let line = format!("{name} = {{ {} }}", parts.join(", "));
    let new = set_entry(&text, section, &name, Some(&line)).or_fail();
    check_manifest(&dir, &new);
    std::fs::write(&file, new).or_fail();
    status("Adding", format!("{name} ({shown}) to {section}"));
}

/// fails unless text is a bolt.toml bolt can read
fn check_manifest(dir: &Path, text: &str) {
    let t = toml::parse(text).unwrap_or_else(|e| fail(format!("the edited bolt.toml wouldn't parse ({e}); left it as it was")));
    if let Err(e) = manifest::parse(dir, &t) {
        fail(format!("{e} (after the edit; left bolt.toml as it was)"));
    }
}

/// `bolt remove NAME...` (from [dev-dependencies] with --dev)
pub fn remove(o: &Opts) {
    if o.words.is_empty() {
        fail("bolt remove NAME...: which dependencies to remove");
    }
    let dir = member_dir(o);
    let file = dir.join("bolt.toml");
    let mut text = std::fs::read_to_string(&file).or_fail();
    let section = if o.dev { "dev-dependencies" } else { "dependencies" };
    for name in &o.words {
        text = set_entry(&text, section, name, None).or_fail();
    }
    check_manifest(&dir, &text);
    std::fs::write(&file, text).or_fail();
    for name in &o.words {
        status("Removing", format!("{name} from {section}"));
    }
}

// ---------- update, fetch ----------

/// resolve the workspace with `lock` (pins written back, unless --locked)
fn resolve_all(o: &Opts, lock: &mut Lock) -> resolve::Graph {
    let ws = manifest::workspace(o.manifest_path.as_deref()).or_fail();
    let _cache = crate::build::lock_file(&resolve::cache_dir().join("lock"));
    resolve::resolve(ws, lock).or_fail()
}

/// `bolt update [NAME...]`: git dependencies (all, or the named ones) move to their newest commit
pub fn update(o: &Opts) {
    let root = manifest::workspace(o.manifest_path.as_deref()).or_fail().root;
    let old = Lock::read(&root, o.offline).or_fail();
    let keys: Vec<(String, String)> = if o.words.is_empty() {
        let mut probe = Lock::read(&root, o.offline).or_fail();
        resolve_all(o, &mut probe).pkgs.iter().filter_map(|p| p.lock_key.clone()).collect()
    } else {
        let mut probe = Lock::read(&root, o.offline).or_fail();
        let g = resolve_all(o, &mut probe);
        o.words.iter().map(|n| g.by_name.get(n).and_then(|i| g.pkgs[*i].lock_key.clone()).unwrap_or_else(|| fail(format!("'{n}' isn't a git dependency here")))).collect()
    };
    let mut lock = Lock::read(&root, o.offline).or_fail();
    lock.unpin(&keys);
    let g = resolve_all(o, &mut lock);
    lock.write(&root, o.locked).or_fail();
    let short = |c: &str| c[..8.min(c.len())].to_string();
    let mut moved = 0;
    for p in g.pkgs.iter().filter(|p| p.lock_key.is_some()) {
        let k = p.lock_key.as_ref().unwrap();
        let (was, now) = (old.pinned(k), lock.pinned(k));
        if was != now {
            moved += 1;
            let was = was.map_or("new".to_string(), |c| short(c));
            status("Updating", format!("{} v{} ({was} -> {})", p.m.name, p.m.version.text, now.map_or(String::new(), |c| short(c))));
        }
    }
    if moved == 0 {
        status("Locking", "git dependencies are up to date");
    }
}

/// `bolt fetch`: every git dependency, into the cache (for building --offline later)
pub fn fetch(o: &Opts) {
    let root = manifest::workspace(o.manifest_path.as_deref()).or_fail().root;
    let mut lock = Lock::read(&root, o.offline).or_fail();
    let g = resolve_all(o, &mut lock);
    lock.write(&root, o.locked).or_fail();
    status("Fetched", format!("{} git dependencies", g.pkgs.iter().filter(|p| p.lock_key.is_some()).count()));
}

// ---------- tree, metadata ----------

/// how tree shows a package: name, version and where it's from
fn describe(b: &Build, p: usize) -> String {
    let pkg = &b.g.pkgs[p];
    let from = match pkg.source.strip_prefix("git+") {
        Some(g) => g.split_once('#').map_or(g.to_string(), |(u, c)| format!("{u}#{}", &c[..8.min(c.len())])),
        None => pkg.m.dir.display().to_string(),
    };
    format!("{} v{} ({from})", pkg.m.name, pkg.m.version.text)
}

/// `bolt tree`: what the selected packages use, as a tree; (*) marks a package shown above
pub fn tree(o: &Opts) {
    let b = Build::new(o, "dev", true);
    fn node(b: &Build, p: usize, prefix: &str, seen: &mut Vec<bool>) {
        let mut kids = b.act.deps[p].clone();
        kids.sort_by(|x, y| b.g.pkgs[*x].m.name.cmp(&b.g.pkgs[*y].m.name));
        kids.dedup();
        for (i, &k) in kids.iter().enumerate() {
            let last = i + 1 == kids.len();
            let again = seen[k] && !b.act.deps[k].is_empty();
            println!("{prefix}{}{}{}", if last { "└── " } else { "├── " }, describe(b, k), if again { " (*)" } else { "" });
            if !again {
                seen[k] = true;
                node(b, k, &format!("{prefix}{}", if last { "    " } else { "│   " }), seen);
            }
        }
    }
    for (n, &r) in b.roots.iter().enumerate() {
        if n > 0 {
            println!();
        }
        println!("{}", describe(&b, r));
        let mut seen = vec![false; b.g.pkgs.len()];
        node(&b, r, "", &mut seen);
        let mut dev = b.act.dev_deps[r].clone();
        dev.sort();
        dev.dedup();
        if !dev.is_empty() {
            println!("[dev-dependencies]");
            for (i, &k) in dev.iter().enumerate() {
                let last = i + 1 == dev.len();
                println!("{}{}", if last { "└── " } else { "├── " }, describe(&b, k));
                node(&b, k, if last { "    " } else { "│   " }, &mut seen);
            }
        }
    }
}

/// a JSON string
fn js(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn js_list<'a>(items: impl IntoIterator<Item = &'a String>) -> String {
    format!("[{}]", items.into_iter().map(|s| js(s)).collect::<Vec<_>>().join(","))
}

/// `bolt metadata`: the workspace as JSON on one line (packages, their targets, dependencies and
/// features, and what a whole-workspace build turns on) for editors and other tools
pub fn metadata(o: &Opts) {
    let mut all = o.clone();
    all.workspace = true;
    let b = Build::new(&all, "dev", true);
    let mut pkgs = Vec::new();
    for p in &b.g.pkgs {
        let m = &p.m;
        let deps: Vec<String> = m
            .deps
            .iter()
            .map(|d| {
                let src = match &d.source {
                    manifest::Source::Path(x) => format!("path+{}", x.canonicalize().unwrap_or(x.clone()).display()),
                    manifest::Source::Git { url, at } => format!("git+{url}{}", if at.spec().is_empty() { String::new() } else { format!("?{}", at.spec()) }),
                };
                format!(
                    "{{\"name\":{},\"kind\":{},\"optional\":{},\"req\":{},\"source\":{},\"features\":{},\"default_features\":{}}}",
                    js(&d.name),
                    if d.dev { "\"dev\"" } else { "null" },
                    d.optional,
                    js(d.req.as_ref().map_or("*", |r| r.text.as_str())),
                    js(&src),
                    js_list(&d.features),
                    d.default_features
                )
            })
            .collect();
        let mut targets: Vec<String> = m.lib.iter().map(|l| format!("{{\"kind\":\"lib\",\"name\":{},\"src_path\":{}}}", js(&m.name), js(&l.display().to_string()))).collect();
        targets.extend(m.targets.iter().map(|t| format!("{{\"kind\":{},\"name\":{},\"src_path\":{},\"required_features\":{}}}", js(t.kind.name()), js(&t.name), js(&t.path.display().to_string()), js_list(&t.required_features))));
        let features: Vec<String> = m.features.iter().map(|(k, v)| format!("{}:{}", js(k), js_list(v))).collect();
        pkgs.push(format!(
            "{{\"name\":{},\"version\":{},\"description\":{},\"source\":{},\"manifest_path\":{},\"dependencies\":[{}],\"targets\":[{}],\"features\":{{{}}}}}",
            js(&m.name),
            js(&m.version.text),
            m.description.as_deref().map_or("null".into(), js),
            js(&p.source),
            js(&m.dir.join("bolt.toml").display().to_string()),
            deps.join(","),
            targets.join(","),
            features.join(",")
        ));
    }
    let names = |v: &[usize]| {
        let mut n: Vec<String> = v.iter().map(|p| b.g.pkgs[*p].m.name.clone()).collect();
        n.sort();
        n.dedup();
        js_list(&n)
    };
    let nodes: Vec<String> = (0..b.g.pkgs.len())
        .filter(|p| b.act.on[*p])
        .map(|p| format!("{{\"id\":{},\"dependencies\":{},\"dev_dependencies\":{},\"features\":{}}}", js(&b.g.pkgs[p].m.name), names(&b.act.deps[p]), names(&b.act.dev_deps[p]), js_list(&b.act.features[p])))
        .collect();
    let members: Vec<String> = b.g.pkgs.iter().filter(|p| p.member).map(|p| p.m.name.clone()).collect();
    println!(
        "{{\"version\":1,\"workspace_root\":{},\"target_directory\":{},\"workspace_members\":{},\"packages\":[{}],\"resolve\":{{\"nodes\":[{}]}}}}",
        js(&b.ws_root.display().to_string()),
        js(&b.target.parent().unwrap_or(&b.target).display().to_string()),
        js_list(&members),
        pkgs.join(","),
        nodes.join(",")
    );
}

// ---------- install, uninstall ----------

/// where install puts executables: --root, $BOLT_INSTALL_ROOT, else ~/.local (then ROOT/bin)
fn install_root(o: &Opts) -> PathBuf {
    if let Some(r) = &o.root {
        return r.clone();
    }
    if let Some(r) = std::env::var_os("BOLT_INSTALL_ROOT") {
        return r.into();
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| fail("HOME isn't set; pass --root DIR"))).join(".local")
}

/// what install recorded: ROOT/share/bolt/installs.toml, package -> (source, executables)
fn installs(root: &Path) -> (PathBuf, Vec<(String, String, Vec<String>)>) {
    let file = root.join("share/bolt/installs.toml");
    let mut v = Vec::new();
    if let Ok(src) = std::fs::read_to_string(&file) {
        let t = toml::parse(&src).unwrap_or_else(|e| fail(format!("{}: {e}", file.display())));
        for e in t.get("install").and_then(Value::as_array).unwrap_or(&[]) {
            let e = e.as_table().unwrap_or_else(|| fail(format!("{} is damaged", file.display())));
            let s = |k: &str| e.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            let bins = e.get("bins").and_then(Value::as_array).unwrap_or(&[]).iter().filter_map(|b| b.as_str().map(String::from)).collect();
            v.push((s("package"), s("source"), bins));
        }
    }
    (file, v)
}

fn write_installs(file: &Path, v: &[(String, String, Vec<String>)]) {
    let mut out = String::from("# written by bolt install: which package each executable came from\n");
    for (p, s, bins) in v {
        out.push_str(&format!("\n[[install]]\npackage = {}\nsource = {}\nbins = [{}]\n", toml::quote(p), toml::quote(s), bins.iter().map(|b| toml::quote(b)).collect::<Vec<_>>().join(", ")));
    }
    std::fs::create_dir_all(file.parent().unwrap()).or_fail();
    std::fs::write(file, out).or_fail();
}

/// `bolt install [--path DIR | --git URL] [--root DIR]`: build a package's executables with the
/// release profile and copy them to ROOT/bin
pub fn install(o: &Opts) {
    let root = install_root(o);
    let mut b_opts = o.clone();
    if let Some(url) = &o.git {
        let at = match (&o.rev, &o.branch, &o.tag) {
            (Some(r), _, _) => GitRef::Rev(r.clone()),
            (_, Some(b), _) => GitRef::Branch(b.clone()),
            (_, _, Some(t)) => GitRef::Tag(t.clone()),
            _ => GitRef::Default,
        };
        let mut lock = Lock::default();
        lock.offline = o.offline;
        let (co, _) = {
            let _cache = crate::build::lock_file(&resolve::cache_dir().join("lock"));
            resolve::fetch(url, &at, &mut lock).or_fail()
        };
        // a checkout is shared: build it in the cache's own target directory
        b_opts.target_dir = Some(o.target_dir.clone().unwrap_or_else(|| resolve::cache_dir().join("install-target").join(format!("{:016x}", resolve::fnv64(url)))));
        b_opts.manifest_path = Some(co);
    } else {
        b_opts.manifest_path = Some(PathBuf::from(o.path.as_deref().unwrap_or(".")));
    }
    let start = std::time::Instant::now();
    let mut b = Build::new(&b_opts, "release", false);
    let [p] = b.roots[..] else { fail("that's a workspace: install one member with --path MEMBER_DIR") };
    let plan = b.plan(p, &o.defines).or_fail();
    let mut exes = b.install_exes(p, &plan);
    if !o.bins.is_empty() {
        exes.retain(|e| o.bins.contains(&e.name));
    }
    let m_name = b.g.pkgs[p].m.name.clone();
    if exes.is_empty() {
        fail(format!("package {m_name} has no executables to install"));
    }
    let (file, mut records) = installs(&root);
    let bin_dir = root.join("bin");
    for e in &exes {
        let dest = bin_dir.join(&e.name);
        if dest.exists() && !o.force {
            let owner = records.iter().find(|r| r.2.contains(&e.name)).map(|r| r.0.clone());
            fail(match owner {
                Some(pk) if pk == m_name => format!("package {m_name} is already installed in {} (pass --force to reinstall it)", root.display()),
                _ => format!("{} already exists (pass --force to overwrite it)", dest.display()),
            });
        }
    }
    b.executables(&exes, &HashMap::from([(p, plan.clone())])).or_fail();
    b.finished(start);
    std::fs::create_dir_all(&bin_dir).or_fail();
    for e in &exes {
        let dest = bin_dir.join(&e.name);
        // copy next to it, then rename: a running copy of the old one keeps working
        let tmp = bin_dir.join(format!(".{}.bolt-tmp", e.name));
        std::fs::copy(&e.out, &tmp).unwrap_or_else(|err| fail(format!("can't copy {} to {}: {err}", e.out.display(), tmp.display())));
        std::fs::rename(&tmp, &dest).or_fail();
        status("Installing", dest.display());
    }
    let names: Vec<String> = exes.iter().map(|e| e.name.clone()).collect();
    for r in records.iter_mut() {
        r.2.retain(|b| !names.contains(b));
    }
    records.retain(|r| r.0 != m_name && !r.2.is_empty());
    records.push((m_name.clone(), b.g.pkgs[p].source.clone(), names.clone()));
    write_installs(&file, &records);
    let list = names.iter().map(|n| format!("`{n}`")).collect::<Vec<_>>().join(", ");
    status("Installed", format!("package `{m_name} v{}` (executable{} {list})", b.g.pkgs[p].m.version.text, if names.len() > 1 { "s" } else { "" }));
    let on_path = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).any(|d| d == bin_dir);
    if !on_path {
        warn(format!("add {} to your PATH to run the installed executables", bin_dir.display()));
    }
}

/// `bolt uninstall NAME...`: remove what install put in ROOT/bin for these packages
pub fn uninstall(o: &Opts) {
    if o.words.is_empty() {
        fail("bolt uninstall NAME...: which packages to remove");
    }
    let root = install_root(o);
    let (file, mut records) = installs(&root);
    for name in &o.words {
        let i = records.iter().position(|r| r.0 == *name).unwrap_or_else(|| fail(format!("package '{name}' isn't installed in {}", root.display())));
        for b in &records[i].2 {
            let p = root.join("bin").join(b);
            let _ = std::fs::remove_file(&p);
            status("Removing", p.display());
        }
        records.remove(i);
    }
    write_installs(&file, &records);
}

