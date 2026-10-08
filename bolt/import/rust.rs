// use { "geom.rs" } as NAME; (one file, a crate of its own) or use { "../geom" } as NAME; (a directory
// with Cargo.toml) — an ordinary Cargo library crate, called from Volt. bolt reads the crate's
// public API as rustdoc sees it (its JSON, which stable's rustdoc writes with RUSTC_BOOTSTRAP=1):
// pub fns, structs, enums, impl blocks' pub fns, consts with their computed values and pub mods,
// including what macros make, what's under a #[cfg] that holds and what `pub use` re-exports, by
// its public path. (Without that JSON, it reads the source, which sees none of those three.) It
// writes a shim crate that depends on the crate and wraps each one in an extern "C" function,
// builds the shim with cargo as a static library, and writes the Volt side (glue.rs). Nothing in
// the crate changes.
//
//   &str, String -> str in, std::string out; &[T], &mut [T], Vec<T> -> T[..] in, std::vec<T> out;
//   Option<T> -> T?; Result<T, E> -> rust_error!T (the Err's to_string()); char -> u32
//   a struct whose fields are all pub and plain -> a Volt struct, by value; any other struct, an
//   enum with data, a #[non_exhaustive] struct -> an owned handle (delete drops it, copy clones it
//   when it's Clone, a method taking self takes the handle and leaves it empty)
//   a fieldless enum -> a Volt enum; pub const of a number, bool or string -> val; pub mod -> namespace
// Generics, traits, closures and references returned into Rust-owned data are left out, with a
// comment in the Volt source (VOLT_SHOW_IMPORT=1 makes voltc print it).
use super::glue::{number, prim, FnPass, Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TraitDef, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use crate::foreign::{int_value, lex, tok_text, toks_line, Cur, Tok};
use crate::json::Json;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let [arg] = r.args.as_slice() else {
        return Err(format!("use {{ \"geom.rs\" }} as {}: name one crate: a .rs file, or a directory with a Cargo.toml", r.alias));
    };
    let path = arg_path(r, arg);
    // dir: where cargo runs (the crate's rust-toolchain.toml); krate: the crate the shim depends on;
    // root and src: its lib.rs and where its `mod x;` files are
    let (dir, krate, root, src, mut files) = if path.is_file() && path.extension().is_some_and(|e| e.eq_ignore_ascii_case("rs")) {
        // one file is a crate of its own: its Cargo.toml goes in the import's directory (named so any
        // file name makes a valid crate name: 2d-shapes.rs is volt_file_2d_shapes)
        let stem: String = path.file_stem().unwrap_or_default().to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
        let stem = format!("volt_file_{stem}");
        let krate = r.out.join("crate");
        let toml = format!("[package]\nname = \"{stem}\"\nversion = \"0.0.0\"\nedition = \"2021\"\npublish = false\n\n[lib]\npath = {:?}\n\n[workspace]\n", path.display().to_string());
        crate::build::write_if_changed(&krate.join("Cargo.toml"), &toml)?;
        let dir = path.parent().map_or_else(|| PathBuf::from("."), Path::to_path_buf);
        let mut files = vec![path.clone()];
        // the files its `mod x;` lines name, next to it
        if let Ok(rd) = std::fs::read_dir(&dir) {
            let mut more: Vec<PathBuf> = rd.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p != &path && p.extension().is_some_and(|e| e == "rs")).collect();
            more.sort();
            files.extend(more);
        }
        (dir.clone(), krate, path.clone(), dir, files)
    } else {
        let manifest = path.join("Cargo.toml");
        if !manifest.is_file() {
            return Err(format!("use {{ \"{arg}\" }}: {} is neither a .rs file nor a directory with a Cargo.toml", path.display()));
        }
        let mut files = vec![manifest, path.join("Cargo.lock")];
        rs_files(&path.join("src"), &mut files);
        (path.clone(), path.clone(), path.join("src/lib.rs"), path.join("src"), files)
    };
    let (pkg, lib) = crate_names(&krate.join("Cargo.toml"))?;
    if !files.contains(&krate.join("Cargo.toml")) {
        files.push(krate.join("Cargo.toml"));
    }
    // the crate's own inputs (the instances rustc rejected stay rejected until these change)
    let crate_st = stamp(&files, "crate");
    // the instances of its generics a program asked for (voltc writes them)
    if r.out.join("instances").is_file() {
        files.push(r.out.join("instances"));
    }
    let st = stamp(&files, &format!("rust {} {} release={}", r.alias, path.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    // the shim crate (its lib.rs comes from the model): rustdoc documents the crate as its
    // dependency, so nothing is written into the crate (not even a Cargo.lock)
    let shim_dir = r.out.join("shim");
    crate::build::write_if_changed(&shim_dir.join("Cargo.toml"), &format!("[package]\nname = \"volt_import_{}\"\nversion = \"0.0.0\"\nedition = \"2021\"\npublish = false\n\n[lib]\npath = \"lib.rs\"\n\n[dependencies]\n{pkg} = {{ path = {:?} }}\n\n[workspace]\n", r.alias, krate.display().to_string()))?;
    if !shim_dir.join("lib.rs").is_file() {
        crate::build::write_if_changed(&shim_dir.join("lib.rs"), "")?;
    }
    let (mut model, doc_only) = match rustdoc_model(&dir, &shim_dir.join("Cargo.toml"), &pkg, &r.out.join("target"), &lib) {
        Ok(read) => read,
        Err(why) => {
            let text = std::fs::read_to_string(&root).map_err(|e| format!("use rust: can't read {}: {e}", root.display()))?;
            let mut w = Walker::default();
            w.walk(&lex(&text), &[], &src);
            let mut m = w.model();
            let note = format!("rustdoc couldn't write JSON bolt reads ({why}), so {} was read from its source: what macros make, what's under #[cfg] and pub use re-exports are left out", path.display());
            eprintln!("bolt: {note}");
            m.left_out.push(format!("({note})"));
            (m, Vec::new())
        }
    };
    // rustdoc sees what's under #[cfg(doc)], which the build doesn't: such an item stays when the
    // build declares one of its name too (rustc's expanded source of the crate says), as a stand-in
    // for the build's (which rustdoc can't see)
    if !doc_only.is_empty() {
        if let Some(real) = build_names(&dir, &shim_dir.join("Cargo.toml"), &pkg, &r.out.join("target")) {
            let gone: Vec<(Vec<String>, String)> = doc_only.into_iter().filter(|(_, n)| !real.contains(n)).collect();
            without(&mut model, &gone);
        }
    }
    let lang = Rust { lib: lib.clone() };
    // the shim crate, with the instances of generics asked for: its own target directory, cargo run
    // from the crate's (its rust-toolchain.toml); its Volt side, or cargo's errors
    let build = |lines: &[String], skip: &BTreeMap<String, String>| -> Result<(String, String), String> {
        let mut m = model.clone();
        instances(&mut m, lines, &r.alias, &lib, skip);
        let (shim, volt) = Gen::new(&m, &r.alias, &lang).write("the crate");
        crate::build::write_if_changed(&shim_dir.join("lib.rs"), &shim)?;
        let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
        c.current_dir(&dir).args(["rustc", "-q", "--lib", "--crate-type", "staticlib", "--manifest-path"]).arg(shim_dir.join("Cargo.toml")).arg("--target-dir").arg(r.out.join("target"));
        if r.release {
            c.arg("--release");
        }
        c.args(["--", "--print", "native-static-libs"]);
        let o = c.output().map_err(|e| format!("can't run cargo: {e}"))?;
        let err = String::from_utf8_lossy(&o.stderr).into_owned();
        if o.status.success() { Ok((volt, err)) } else { Err(err) }
    };
    // the instances programs asked for. Those rustc rejected (OUT/instances.failed: a line, or a
    // line and ::method for one method of a type's instance, then rustc's reason) stay out until
    // the crate changes; then they're tried again
    let mut wanted: Vec<String> = std::fs::read_to_string(r.out.join("instances")).unwrap_or_default().lines().filter(|l| !l.trim().is_empty()).map(String::from).collect();
    let failed_file = r.out.join("instances.failed");
    let old_failed = std::fs::read_to_string(&failed_file).unwrap_or_default();
    let mut failed = format!("# {}\n", crate_st.replace('\n', " "));
    let mut skip: BTreeMap<String, String> = BTreeMap::new();
    if old_failed.lines().next() == failed.lines().next() {
        for l in old_failed.lines().skip(1) {
            let mut f = l.splitn(3, '\t');
            let (line, rest) = (f.next().unwrap_or(""), f.next().unwrap_or(""));
            match rest.strip_prefix("::") {
                Some(method) => {
                    skip.insert(format!("{line}::{method}"), f.next().unwrap_or("").to_string());
                }
                None => wanted.retain(|w| w != line),
            }
            if !failed.lines().any(|x| x == l) {
                let _ = writeln!(failed, "{l}");
            }
        }
    } else {
        for l in old_failed.lines().skip(1) {
            let line = l.split('\t').next().unwrap_or("").to_string();
            if !line.is_empty() && !wanted.contains(&line) {
                wanted.push(line);
            }
        }
    }
    let (volt, err) = match build(&wanted, &skip) {
        Ok(x) => {
            crate::build::write_if_changed(&failed_file, &failed)?;
            x
        }
        Err(e) if wanted.is_empty() => return Err(format!("use rust: cargo couldn't build the glue for {}:\n{e}", dir.display())),
        Err(_) => {
            // an instance rustc rejects (types that don't meet a bound) is left out, with rustc's
            // reason (voltc reports it at the call); of a type's instance, only the methods it
            // rejects (each impl block has its own bounds)
            let why = |e: &str| e.lines().find(|x| x.starts_with("error")).unwrap_or("rustc rejected it").trim().to_string();
            let mut good: Vec<String> = Vec::new();
            for l in &wanted {
                let mut with = good.clone();
                with.push(l.clone());
                let Err(e) = build(&with, &skip) else {
                    good = with;
                    continue;
                };
                let mut probe = model.clone();
                let made = instances(&mut probe, std::slice::from_ref(l), &r.alias, &lib, &skip);
                let methods: Vec<String> = made.first().cloned().flatten().and_then(|t| probe.methods.get(&t).cloned()).unwrap_or_default().into_iter().map(|s| s.name).collect();
                let mut bare = skip.clone();
                for m in &methods {
                    bare.entry(format!("{l}::{m}")).or_insert_with(|| "left out while its type was tried".into());
                }
                if methods.is_empty() || build(&with, &bare).is_err() {
                    let _ = writeln!(failed, "{l}\t{}", why(&e));
                    continue;
                }
                good = with;
                for m in &methods {
                    let key = format!("{l}::{m}");
                    if skip.contains_key(&key) {
                        continue;
                    }
                    bare.remove(&key);
                    if let Err(e) = build(&good, &bare) {
                        let w = why(&e);
                        let entry = format!("{l}\t::{m}\t{w}");
                        if !failed.lines().any(|x| x == entry) {
                            let _ = writeln!(failed, "{entry}");
                        }
                        bare.insert(key.clone(), w.clone());
                        skip.insert(key, w);
                    }
                }
            }
            crate::build::write_if_changed(&r.out.join("instances"), &good.iter().map(|l| format!("{l}\n")).collect::<String>())?;
            crate::build::write_if_changed(&failed_file, &failed)?;
            build(&good, &skip).map_err(|e| format!("use rust: cargo couldn't build the glue for {}:\n{e}", dir.display()))?
        }
    };
    let lib_file = r.out.join("target").join(if r.release { "release" } else { "debug" }).join(format!("libvolt_import_{}.a", r.alias));
    let mut flags = vec![lib_file.display().to_string()];
    for line in err.lines() {
        if let Some(libs) = line.split("native-static-libs:").nth(1) {
            for l in libs.split_whitespace() {
                if !flags.iter().any(|x| x == l) {
                    flags.push(l.to_string());
                }
            }
        }
    }
    save(r, &Made { volt, flags, deps: files }, &st)
}

/// the package's name and its library's (as Rust code names it)
fn crate_names(manifest: &Path) -> Result<(String, String), String> {
    let text = std::fs::read_to_string(manifest).map_err(|e| format!("can't read {}: {e}", manifest.display()))?;
    let t = crate::toml::parse(&text).map_err(|e| format!("{}: {e}", manifest.display()))?;
    let get = |table: &str, key: &str| t.get(table).and_then(|v| v.as_table()).and_then(|v| v.get(key)).and_then(|v| v.as_str()).map(String::from);
    let pkg = get("package", "name").ok_or(format!("{} has no [package] name", manifest.display()))?;
    let lib = get("lib", "name").unwrap_or_else(|| pkg.clone()).replace('-', "_");
    Ok((pkg, lib))
}

fn rs_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<_> = rd.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for p in paths {
        if p.is_dir() {
            rs_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

// ---------- the crate's public API, as rustdoc sees it ----------

/// the crate's public API from rustdoc's JSON, documenting package pkg as the shim's dependency, and
/// the items only under #[cfg(doc)] (module, name); why not, when rustdoc can't write it (an older
/// toolchain, no rustdoc) or writes a format this doesn't read
fn rustdoc_model(dir: &Path, shim: &Path, pkg: &str, target: &Path, lib: &str) -> Result<(Model, Vec<(Vec<String>, String)>), String> {
    let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
    c.current_dir(dir).env("RUSTC_BOOTSTRAP", "1").args(["rustdoc", "-q", "--lib", "-p", pkg, "--manifest-path"]).arg(shim).arg("--target-dir").arg(target);
    c.args(["--", "-Z", "unstable-options", "--output-format", "json"]);
    let o = c.output().map_err(|e| format!("can't run cargo rustdoc: {e}"))?;
    if !o.status.success() {
        let err = String::from_utf8_lossy(&o.stderr);
        return Err(err.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("cargo rustdoc failed").trim().to_string());
    }
    let file = target.join("doc").join(format!("{lib}.json"));
    let text = std::fs::read_to_string(&file).map_err(|e| format!("can't read {}: {e}", file.display()))?;
    let j = crate::json::parse(&text)?;
    Doc::read(&j, dir).ok_or_else(|| format!("its JSON (format {}) isn't one bolt reads", j.get("format_version").and_then(Json::key).unwrap_or_default()))
}

/// the names of the pub items the build of package pkg declares (fns, types, consts, in any module),
/// from rustc's macro-expanded source of it; None when rustc can't write that
fn build_names(dir: &Path, shim: &Path, pkg: &str, target: &Path) -> Option<BTreeSet<String>> {
    let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
    c.current_dir(dir).env("RUSTC_BOOTSTRAP", "1").args(["rustc", "-q", "--lib", "-p", pkg, "--manifest-path"]).arg(shim).arg("--target-dir").arg(target);
    c.args(["--", "-Z", "unpretty=expanded"]);
    let o = c.output().ok()?;
    if !o.status.success() {
        return None;
    }
    let mut w = Walker::default();
    w.walk(&lex(&String::from_utf8_lossy(&o.stdout)), &[], dir);
    let m = w.model();
    let mut out: BTreeSet<String> = m.fns.iter().map(|(_, s)| s.name.clone()).collect();
    out.extend(m.types.iter().map(|t| t.name.clone()));
    out.extend(m.consts.iter().map(|c| c.1.clone()));
    out.extend(m.left_out.iter().filter_map(|l| l.strip_prefix("const ")).filter_map(|l| l.split_whitespace().next()).map(String::from));
    Some(out)
}

// ---------- generics, per instance ----------

/// The instances voltc asked for (OUT/instances: a line per instance, `module::fn` or
/// `module::Type::method`, then each type argument as Volt names it, tab-separated), each made a
/// function of its own: NAME__ARGS in Volt (the args as an identifier, as voltc spells them), calling
/// NAME::<ARGS> in Rust
/// made of each line: the type instance's name, for a type's
fn instances(m: &mut Model, lines: &[String], alias: &str, lib: &str, skip: &BTreeMap<String, String>) -> Vec<Option<String>> {
    let mut types: BTreeMap<String, Vec<String>> = m.types.iter().map(|t| (t.name.clone(), t.module.clone())).collect();
    let mut made = Vec::new();
    for line in lines {
        made.push(None);
        let mut parts = line.split('\t');
        let Some(path) = parts.next().filter(|p| !p.is_empty()) else { continue };
        let args: Vec<&str> = parts.collect();
        let segs: Vec<String> = path.split("::").map(String::from).collect();
        let Some((name, owner)) = segs.split_last() else { continue };
        // a generic type's instance: the type with its arguments in place, and its methods
        if let Some(gt) = m.types.iter().find(|t| t.module[..] == owner[..] && t.name == *name && !t.params.is_empty()).cloned() {
            let what = format!("{path}<{}>", args.join(", "));
            let inst = format!("{name}__{}", args.iter().map(|a| ident(a)).collect::<Vec<_>>().join("_"));
            if types.contains_key(&inst) {
                continue;
            }
            if args.len() != gt.params.len() {
                m.left_out.push(format!("{what} (it takes {} types)", gt.params.len()));
                continue;
            }
            let mut subst = BTreeMap::new();
            let mut rust = Vec::new();
            for (gp, a) in gt.params.iter().zip(&args) {
                if let Some(t) = volt_ty(a, alias, &types) {
                    rust.push(rust_ty(&t, lib, &types));
                    subst.insert(gp.clone(), t);
                }
            }
            if subst.len() != args.len() {
                m.left_out.push(format!("{what} (a type argument has no Rust type here)"));
                continue;
            }
            let mut d = gt.clone();
            d.name = inst.clone();
            d.generic = false;
            d.params.clear();
            d.rust_name = Some(format!("{name}<{}>", rust.join(", ")));
            d.fields = d.fields.map(|fs| fs.into_iter().map(|(n, p, t)| (n, p, t.map(|t| substitute(&t, &subst)))).collect());
            subst.insert(format!("type {name}"), Ty::Named(inst.clone()));
            let mut ms: Vec<Sig> = Vec::new();
            for mut s in m.methods.get(name).cloned().unwrap_or_default() {
                if let Some(w) = skip.get(&format!("{line}::{}", s.name)) {
                    m.left_out.push(format!("{inst}::{} (rustc: {w})", s.name));
                    continue;
                }
                s.params = s.params.iter().map(|(n, t)| (n.clone(), t.as_ref().map(|t| substitute(t, &subst)))).collect();
                s.ret = s.ret.as_ref().map(|t| substitute(t, &subst));
                ms.push(s);
            }
            m.methods.insert(inst.clone(), ms);
            *made.last_mut().unwrap() = Some(inst.clone());
            types.insert(inst, d.module.clone());
            m.types.push(d);
            continue;
        }
        // a method of a type (the segment before it names one in that module), or a fn
        let method = owner.last().filter(|t| types.get(*t).is_some_and(|tm| tm[..] == owner[..owner.len() - 1]));
        let found = match method {
            Some(t) => m.methods.get(t).and_then(|ms| ms.iter().find(|s| s.name == *name && !s.generics.is_empty())).cloned(),
            None => m.fns.iter().find(|(md, s)| md[..] == owner[..] && s.name == *name && !s.generics.is_empty()).map(|x| x.1.clone()),
        };
        let Some(g) = found else { continue };
        let what = format!("{path}<{}>", args.join(", "));
        if args.len() != g.generics.len() {
            m.left_out.push(format!("{what} (it takes {} types)", g.generics.len()));
            continue;
        }
        let mut subst = BTreeMap::new();
        let mut rust = Vec::new();
        let mut ok = true;
        for (gp, a) in g.generics.iter().zip(&args) {
            match volt_ty(a, alias, &types) {
                Some(t) => {
                    rust.push(rust_ty(&t, lib, &types));
                    subst.insert(gp.clone(), t);
                }
                None => {
                    m.left_out.push(format!("{what} (Volt's {a} has no Rust type here)"));
                    ok = false;
                }
            }
        }
        if !ok {
            continue;
        }
        let mut s = g.clone();
        s.params = s.params.iter().map(|(n, t)| (n.clone(), t.as_ref().map(|t| substitute(t, &subst)))).collect();
        s.ret = s.ret.as_ref().map(|t| substitute(t, &subst));
        s.generics.clear();
        s.call = Some(format!("{name}::<{}>", rust.join(", ")));
        s.name = format!("{name}__{}", args.iter().map(|a| ident(a)).collect::<Vec<_>>().join("_"));
        s.src = format!("{} [{}]", s.src, g.generics.iter().zip(&args).map(|(p, a)| format!("{p} = {a}")).collect::<Vec<_>>().join(", "));
        match method {
            Some(t) => m.methods.entry(t.clone()).or_default().push(s),
            None => m.fns.push((owner.to_vec(), s)),
        }
    }
    made
}

/// a Volt type name as an identifier: std::vec<i32> is std_vec_i32 (voltc's ident_of)
fn ident(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        } else if !out.is_empty() && !out.ends_with('_') {
            out.push('_');
        }
    }
    out.trim_end_matches('_').to_string()
}

/// the type a Volt type name stands for in the crate (alias:: names one of its types)
fn volt_ty(v: &str, alias: &str, types: &BTreeMap<String, Vec<String>>) -> Option<Ty> {
    let v = v.trim();
    if let Some(inner) = v.strip_suffix('?') {
        return Some(Ty::Opt(Box::new(volt_ty(inner, alias, types)?)));
    }
    if let Some(p) = prim(v) {
        return Some(Ty::Prim(p));
    }
    if v == "str" {
        return Some(Ty::Str);
    }
    if v == "std::string" || v.starts_with("std::string<") {
        return Some(Ty::String);
    }
    if let Some(inner) = v.strip_prefix("std::vec<").and_then(|x| x.strip_suffix('>')) {
        // std::vec<T, A>: its allocator isn't Rust's business
        let mut depth = 0;
        let end = inner.char_indices().find(|&(_, c)| {
            match c {
                '<' => depth += 1,
                '>' => depth -= 1,
                _ => {}
            }
            c == ',' && depth == 0
        });
        let elem = &inner[..end.map_or(inner.len(), |(i, _)| i)];
        return Some(Ty::Vec(Box::new(volt_ty(elem, alias, types)?)));
    }
    let local = v.strip_prefix(alias)?.strip_prefix("::")?;
    let segs: Vec<&str> = local.split("::").collect();
    let (name, module) = segs.split_last()?;
    let tm = types.get(*name)?;
    (tm.iter().map(|m| crate::import::volt_name(m)).collect::<Vec<_>>() == module.iter().map(|m| m.to_string()).collect::<Vec<_>>()).then(|| Ty::Named(name.to_string()))
}

/// a type as Rust code names it from the shim
fn rust_ty(t: &Ty, lib: &str, types: &BTreeMap<String, Vec<String>>) -> String {
    match t {
        Ty::Prim(p) => p.to_string(),
        Ty::Char => "char".into(),
        Ty::Str => "&str".into(),
        Ty::String => "String".into(),
        Ty::Vec(e) => format!("Vec<{}>", rust_ty(e, lib, types)),
        Ty::Opt(e) => format!("Option<{}>", rust_ty(e, lib, types)),
        Ty::Named(n) => {
            let mut p = vec![lib.to_string()];
            p.extend(types.get(n).cloned().unwrap_or_default());
            p.push(n.clone());
            format!("::{}", p.join("::"))
        }
        _ => "_".into(),
    }
}

/// a closure as Rust holds it for Volt: dyn FnMut(A) -> R (or FnOnce), as Rust names its types
fn dyn_fn(ps: &[Ty], r: &Ty, once: bool) -> Option<String> {
    let mut a = Vec::new();
    for p in ps {
        a.push(match p {
            Ty::Prim(x) => x.to_string(),
            Ty::Char => "char".into(),
            Ty::Str => "&str".into(),
            Ty::String => "String".into(),
            _ => return None,
        });
    }
    let ret = match r {
        Ty::Unit => String::new(),
        Ty::Prim(x) => format!(" -> {x}"),
        Ty::Char => " -> char".into(),
        Ty::String => " -> String".into(),
        _ => return None,
    };
    Some(format!("dyn {}({}){ret}", if once { "FnOnce" } else { "FnMut" }, a.join(", ")))
}

/// what a closure's handle points at: Box<dyn FnMut(..)>, or Option<Box<dyn FnOnce(..)>> (taken
/// by its one call)
fn held_fn(ps: &[Ty], r: &Ty, once: bool) -> Option<String> {
    let d = dyn_fn(ps, r, once)?;
    Some(if once { format!("Option<Box<{d}>>") } else { format!("Box<{d}>") })
}

/// t with its type parameters replaced (and a generic type, "type NAME", by its instance)
fn substitute(t: &Ty, s: &BTreeMap<String, Ty>) -> Ty {
    match t {
        Ty::Generic(g) => s.get(g).cloned().unwrap_or_else(|| t.clone()),
        Ty::Named(n) => s.get(&format!("type {n}")).cloned().unwrap_or_else(|| t.clone()),
        Ty::Slice(e, m) => Ty::Slice(Box::new(substitute(e, s)), *m),
        Ty::Vec(e) => Ty::Vec(Box::new(substitute(e, s))),
        Ty::Opt(e) => Ty::Opt(Box::new(substitute(e, s))),
        Ty::Res(e) => Ty::Res(Box::new(substitute(e, s))),
        // a closure parameter's type stands for the closure itself
        Ty::Fn(ps, r, p, once) => Ty::Fn(ps.iter().map(|x| substitute(x, s)).collect(), Box::new(substitute(r, s)), *p, *once),
        // &T of text is str and of a Vec a slice, as the reader maps them; of a number it stays a
        // reference (the generic's Volt side takes T&)
        Ty::Ref(e, m) => match (substitute(e, s), *m) {
            (Ty::String | Ty::Str, false) => Ty::Str,
            // &F of a closure type: the closure, lent (and &S of a trait's type, its value)
            (Ty::Fn(ps, r, _, o), m) => Ty::Fn(ps, r, if m { FnPass::MutRef } else { FnPass::Ref }, o),
            (Ty::Dyn(tr, _), m) => Ty::Dyn(tr, if m { FnPass::MutRef } else { FnPass::Ref }),
            (Ty::Vec(x), m) => Ty::Slice(x, m),
            (x, m) => Ty::Ref(Box::new(x), m),
        },
        _ => t.clone(),
    }
}

/// the model without these items (module, name)
fn without(m: &mut Model, gone: &[(Vec<String>, String)]) {
    let has = |module: &Vec<String>, name: &str| gone.iter().any(|(gm, gn)| gm == module && gn == name);
    m.fns.retain(|(module, s)| !has(module, &s.name));
    m.consts.retain(|(module, name, _, _)| !has(module, name));
    let types: Vec<String> = m.types.iter().filter(|t| has(&t.module, &t.name)).map(|t| t.name.clone()).collect();
    // a trait gone takes its objects' handle (dyn_T) with it
    let traits: Vec<String> = m.traits.iter().filter(|t| has(&t.module, &t.name)).map(|t| format!("dyn_{}", t.name)).collect();
    m.traits.retain(|t| !has(&t.module, &t.name));
    m.types.retain(|t| !has(&t.module, &t.name) && !traits.contains(&t.name));
    let gone_traits: Vec<String> = traits.iter().map(|t| t["dyn_".len()..].to_string()).collect();
    m.impls.retain(|(ty, tr)| !traits.contains(ty) && !gone_traits.contains(tr) && !types.contains(ty));
    for t in types {
        m.methods.remove(&t);
    }
}

/// rustdoc's index, read into the model
struct Doc<'a> {
    idx: &'a BTreeMap<String, Json>,
    dir: &'a Path,
    m: Model,
    /// each public type's name, by id: its shallowest public path's
    names: BTreeMap<String, String>,
    /// the items under a #[cfg] that names doc (rustdoc sets it; the build doesn't)
    doc_only: Vec<(Vec<String>, String)>,
    /// the crate's name, and its public traits' names by id
    lib: String,
    traits: BTreeMap<String, String>,
}

impl<'a> Doc<'a> {
    fn read(j: &'a Json, dir: &'a Path) -> Option<(Model, Vec<(Vec<String>, String)>)> {
        // the formats this reads (an item's kind as the key of its inner): 40 on, and a newer one is
        // tried; one whose keys moved shows up as a crate with nothing public, below
        if j.get("format_version").and_then(Json::key).and_then(|v| v.parse::<u32>().ok()).is_none_or(|v| v < 40) {
            return None;
        }
        let idx = j.get("index")?.obj()?;
        let root = j.get("root")?.key()?;
        let root_items = idx.get(&root)?.get("inner")?.get("module")?.get("items")?.arr().len();
        let lib = idx.get(&root)?.get("name").and_then(Json::str)?.to_string();
        let mut d = Doc { idx, dir, m: Model::default(), names: BTreeMap::new(), doc_only: Vec::new(), lib, traits: BTreeMap::new() };
        let mut items = d.public(&root);
        // an item reached twice at one path (pub use a::X next to pub use a::*) is one item
        let mut once = BTreeSet::new();
        items.retain(|(module, id, name)| once.insert((module.clone(), id.clone(), name.clone())));
        if root_items > 0 && items.is_empty() && idx.values().filter(|it| it.get("crate_id").and_then(Json::key).as_deref() == Some("0")).any(|it| it.get("visibility").and_then(Json::str) == Some("public") && it.get("inner").and_then(|i| i.get("function")).is_some()) {
            return None;
        }
        for (_, id, name) in &items {
            let inner = d.idx.get(id).and_then(|it| it.get("inner"));
            if inner.is_some_and(|i| i.get("struct").is_some() || i.get("enum").is_some()) && !d.names.contains_key(id) {
                d.names.insert(id.clone(), name.clone());
            }
            if inner.is_some_and(|i| i.get("trait").is_some()) && !d.traits.contains_key(id) {
                d.traits.insert(id.clone(), name.clone());
            }
        }
        let mut made = BTreeSet::new();
        for (module, id, name) in items {
            let Some(it) = d.idx.get(&id) else { continue };
            let Some(inner) = it.get("inner") else { continue };
            if under_cfg_doc(it) {
                d.doc_only.push((module.clone(), name.clone()));
            }
            if let Some(f) = inner.get("function") {
                let s = d.sig(it, f, &name);
                d.m.fns.push((module, s));
            } else if let Some(body) = inner.get("struct").or_else(|| inner.get("enum")) {
                // a type re-exported again is the same type, under its shallowest path
                if made.insert(id.clone()) {
                    d.typedef(module, name, it, body, inner.get("enum").is_some());
                }
            } else if let Some(c) = inner.get("constant") {
                d.constant(module, name, c);
            } else if let Some(t) = inner.get("trait") {
                if made.insert(id.clone()) {
                    d.traitdef(module, name, t);
                }
            }
        }
        Some((d.m, d.doc_only))
    }

    /// every public item reachable from module `root`, with the module path and name it's public
    /// under: modules breadth first (a re-export nearer the root names a type), `pub use` followed
    /// (a glob brings in a module's items), each module once per path
    fn public(&self, root: &str) -> Vec<(Vec<String>, String, String)> {
        let mut out = Vec::new();
        let mut walked = BTreeSet::new();
        // a module, the path it's public at, and the modules entered to reach it: a glob of an
        // enclosing module (pub mod prelude { pub use super::*; }) brings its items in, but a module
        // is never entered again inside itself (Rust's prelude::prelude::... goes on forever)
        let mut queue = std::collections::VecDeque::from([(root.to_string(), Vec::<String>::new(), vec![root.to_string()])]);
        while let Some((mid, path, chain)) = queue.pop_front() {
            // ponytail: modules globbing each other in a ring multiply paths; capped, not pruned
            if walked.len() > 10_000 || !walked.insert((mid.clone(), path.clone())) {
                continue;
            }
            let mut push = |tid: String, p: Vec<String>, glob: bool| {
                if if glob { tid != mid } else { !chain.contains(&tid) } {
                    let mut c = chain.clone();
                    c.push(tid.clone());
                    queue.push_back((tid, p, c));
                }
            };
            let Some(items) = self.idx.get(&mid).and_then(|m| m.get("inner")).and_then(|i| i.get("module")).and_then(|m| m.get("items")) else { continue };
            for iid in items.arr() {
                let Some(id) = iid.key() else { continue };
                let Some(it) = self.idx.get(&id) else { continue };
                if it.get("visibility").and_then(Json::str) != Some("public") {
                    continue;
                }
                let Some(inner) = it.get("inner") else { continue };
                if let Some(u) = inner.get("use") {
                    // an item of another crate that rustdoc didn't inline has no entry here
                    let Some(tid) = u.get("id").and_then(Json::key) else { continue };
                    let Some(target) = self.idx.get(&tid) else { continue };
                    let is_mod = target.get("inner").and_then(|i| i.get("module")).is_some();
                    let Some(name) = u.get("name").and_then(Json::str) else { continue };
                    if u.get("is_glob").and_then(Json::bool) == Some(true) {
                        if is_mod {
                            push(tid, path.clone(), true);
                        }
                    } else if is_mod {
                        let mut p = path.clone();
                        p.push(name.to_string());
                        push(tid, p, false);
                    } else {
                        out.push((path.clone(), tid, name.to_string()));
                    }
                    continue;
                }
                let Some(name) = it.get("name").and_then(Json::str) else { continue };
                if inner.get("module").is_some() {
                    let mut p = path.clone();
                    p.push(name.to_string());
                    push(id, p, false);
                } else {
                    out.push((path.clone(), id, name.to_string()));
                }
            }
        }
        out
    }

    /// a function or method, under the name it's called by
    fn sig(&self, it: &Json, f: &Json, name: &str) -> Sig {
        let mut s = Sig { name: name.to_string(), recv: Recv::None, params: Vec::new(), ret: Some(Ty::Unit), skip: None, src: self.src(it, name), generics: Vec::new(), call: None };
        let generics = f.get("generics");
        if f.get("header").and_then(|h| h.get("is_async")).and_then(Json::bool) == Some(true) {
            s.skip = Some("it's async");
        }
        // type parameters make a generic fn, built per instance a program uses (their bounds are
        // rustc's to check, for each); one bound by Fn, FnMut or FnOnce (inline or in a where
        // clause; impl Fn(..) is one too) is a closure Volt passes; a const parameter, or an impl
        // Trait one that isn't a closure, isn't one of those
        // each type parameter's bounds, inline and in where clauses together (T: Shape where T:
        // Clone asks more than Shape: it stays a generic)
        let mut bounds: BTreeMap<String, Vec<Json>> = BTreeMap::new();
        for w in generics.and_then(|g| g.get("where_predicates")).map_or(&[][..], Json::arr) {
            let Some(bp) = w.get("bound_predicate") else { continue };
            let Some(n) = bp.get("type").and_then(|t| t.get("generic")).and_then(Json::str) else { continue };
            bounds.entry(n.to_string()).or_default().extend(bp.get("bounds").map_or(&[][..], Json::arr).iter().cloned());
        }
        for p in generics.and_then(|g| g.get("params")).map_or(&[][..], Json::arr) {
            if let (Some(n), Some(t)) = (p.get("name").and_then(Json::str), p.get("kind").and_then(|k| k.get("type"))) {
                bounds.entry(n.to_string()).or_default().extend(t.get("bounds").map_or(&[][..], Json::arr).iter().cloned());
            }
        }
        let mut closures: BTreeMap<String, Ty> = BTreeMap::new();
        for (n, list) in bounds {
            let list = Json::Arr(list);
            if let Some(f) = self.fn_bound(Some(&list), FnPass::Value) {
                closures.insert(n, f);
            } else if let Some(tr) = self.trait_bound(Some(&list)) {
                // a type bound by one of the crate's traits (impl Trait, or S: Trait): a Volt
                // value attaching it
                closures.insert(n, Ty::Dyn(tr, FnPass::Value));
            }
        }
        for p in generics.and_then(|g| g.get("params")).map_or(&[][..], Json::arr) {
            let Some(k) = p.get("kind") else { continue };
            if k.get("lifetime").is_some() {
                continue;
            }
            let name = p.get("name").and_then(Json::str).unwrap_or("");
            let Some(t) = k.get("type") else {
                s.skip = Some("it's generic over more than types");
                continue;
            };
            if closures.contains_key(name) {
                continue;
            }
            if t.get("is_synthetic").and_then(Json::bool) == Some(true) {
                s.skip = Some("it's generic over more than types");
            } else {
                s.generics.push(name.to_string());
            }
        }
        let Some(sig) = f.get("sig") else {
            s.skip = Some("its parameters");
            return s;
        };
        if sig.get("is_c_variadic").and_then(Json::bool) == Some(true) {
            s.skip = Some("it's variadic");
        }
        for (n, p) in sig.get("inputs").map_or(&[][..], Json::arr).iter().enumerate() {
            let [pn, pt] = p.arr() else {
                s.skip = Some("a parameter");
                continue;
            };
            let pname = pn.str().unwrap_or("");
            if n == 0 && pname == "self" {
                let by_ref = pt.get("borrowed_ref");
                let target = by_ref.and_then(|r| r.get("type")).unwrap_or(pt);
                s.recv = match (target.get("generic").and_then(Json::str), by_ref) {
                    (Some("Self"), None) => Recv::Value,
                    (Some("Self"), Some(r)) if r.get("is_mutable").and_then(Json::bool) == Some(true) => Recv::Mut,
                    (Some("Self"), Some(_)) => Recv::Ref,
                    _ => {
                        s.skip = Some("its self parameter");
                        Recv::None
                    }
                };
                continue;
            }
            // a pattern (a tuple, _) is no name
            let named = !pname.is_empty() && pname != "_" && pname.chars().all(|c| c.is_alphanumeric() || c == '_');
            let pname = if named { pname.to_string() } else { format!("a{n}") };
            s.params.push((pname, self.ty(pt)));
        }
        s.ret = match sig.get("output") {
            None | Some(Json::Null) => Some(Ty::Unit),
            Some(t) => self.ty(t),
        };
        if !closures.is_empty() {
            s.params = s.params.iter().map(|(n, t)| (n.clone(), t.as_ref().map(|t| substitute(t, &closures)))).collect();
            s.ret = s.ret.as_ref().map(|t| substitute(t, &closures));
        }
        s
    }

    /// the closure a trait bound list names (Fn, FnMut or FnOnce with its arguments), passed so
    fn fn_bound(&self, bounds: Option<&Json>, pass: FnPass) -> Option<Ty> {
        // F: Fn(..) + Clone asks more of F than a Volt closure has
        let others = bounds.map_or(&[][..], Json::arr).iter().any(|b| {
            let tr = b.get("trait_bound").and_then(|x| x.get("trait")).or_else(|| b.get("trait"));
            tr.is_some_and(|t| !matches!(t.get("path").and_then(Json::str).and_then(|p| p.rsplit("::").next()), Some("Fn" | "FnMut" | "FnOnce" | "Send" | "Sync" | "Sized")))
        });
        if others {
            return None;
        }
        for b in bounds.map_or(&[][..], Json::arr) {
            let tr = b.get("trait_bound").and_then(|x| x.get("trait")).or_else(|| b.get("trait"));
            let Some(tr) = tr else { continue };
            let Some(kind) = tr.get("path").and_then(Json::str).and_then(|p| p.rsplit("::").next()) else { continue };
            if !matches!(kind, "Fn" | "FnMut" | "FnOnce") {
                continue;
            }
            let pa = tr.get("args").and_then(|a| a.get("parenthesized"))?;
            let mut ps = Vec::new();
            for i in pa.get("inputs").map_or(&[][..], Json::arr) {
                ps.push(self.ty(i)?);
            }
            let r = match pa.get("output") {
                None | Some(Json::Null) => Ty::Unit,
                Some(o) => self.ty(o)?,
            };
            return Some(Ty::Fn(ps, Box::new(r), pass, kind == "FnOnce"));
        }
        None
    }

    /// the crate's trait a bound list names, when that's all it asks (Send, Sync and Sized aside)
    fn trait_bound(&self, bounds: Option<&Json>) -> Option<String> {
        let mut found = None;
        for b in bounds.map_or(&[][..], Json::arr) {
            let tr = b.get("trait_bound").and_then(|x| x.get("trait")).or_else(|| b.get("trait"));
            let Some(tr) = tr else { continue };
            if let Some(name) = tr.get("id").and_then(Json::key).and_then(|id| self.traits.get(&id)) {
                if found.is_some() || tr.get("args").is_some_and(|a| !a.is_null()) {
                    return None;
                }
                found = Some(name.clone());
            } else if !matches!(tr.get("path").and_then(Json::str).and_then(|p| p.rsplit("::").next()), Some("Send" | "Sync" | "Sized")) {
                return None;
            }
        }
        found
    }

    /// a trait: its methods (called through it: Trait::method(x, ..)), and its objects' handle
    /// (dyn_T) when it can make them; it and that handle attached by the types implementing it
    fn traitdef(&mut self, module: Vec<String>, name: String, t: &Json) {
        let mut path = vec![String::new(), self.lib.clone()];
        path.extend(module.iter().cloned());
        path.push(name.clone());
        let path = path.join("::");
        let mut td = TraitDef { module: module.clone(), name: name.clone(), methods: Vec::new(), skip: None };
        if generic(t.get("generics")) {
            td.skip = Some("it's generic".into());
        }
        for b in t.get("bounds").map_or(&[][..], Json::arr) {
            let sup = b.get("trait_bound").and_then(|x| x.get("trait")).and_then(|x| x.get("path")).and_then(Json::str).and_then(|p| p.rsplit("::").next()).unwrap_or("?");
            if !matches!(sup, "Send" | "Sync" | "Sized") {
                td.skip = Some(format!("it extends {sup}"));
            }
        }
        for iid in t.get("items").map_or(&[][..], Json::arr) {
            let Some(it) = iid.key().and_then(|k| self.idx.get(&k)) else { continue };
            let Some(inner) = it.get("inner") else { continue };
            let mname = it.get("name").and_then(Json::str).unwrap_or("_");
            if let Some(f) = inner.get("function") {
                let mut s = self.sig(it, f, mname);
                s.call = Some(format!("{path}::{mname}"));
                td.methods.push((s, f.get("has_body").and_then(Json::bool) == Some(true)));
            } else if inner.get("assoc_type").is_some() {
                td.skip = Some(format!("its associated type {mname}"));
            } else if inner.get("assoc_const").is_some() {
                td.skip = Some(format!("its associated const {mname}"));
            }
        }
        // the crate's types implementing it (not a generic one's instances, or a blanket impl)
        for iid in t.get("implementations").map_or(&[][..], Json::arr) {
            let Some(im) = iid.key().and_then(|k| self.idx.get(&k)).and_then(|x| x.get("inner")).and_then(|i| i.get("impl")) else { continue };
            if im.get("blanket_impl").is_some_and(|b| !b.is_null()) || generic(im.get("generics")) {
                continue;
            }
            let Some(rp) = im.get("for").and_then(|f| f.get("resolved_path")) else { continue };
            if let Some(ty) = rp.get("id").and_then(Json::key).and_then(|id| self.names.get(&id)) {
                self.m.impls.push((ty.clone(), name.clone()));
            }
        }
        let dyn_ok = t.get("is_dyn_compatible").or_else(|| t.get("is_object_safe")).and_then(Json::bool) == Some(true);
        if dyn_ok && td.skip.is_none() {
            let h = format!("dyn_{name}");
            self.m.types.push(TypeDef { module, name: h.clone(), generic: false, fields: None, variants: None, is_enum: false, clone: false, opaque: true, params: Vec::new(), rust_name: Some(format!("{DYN_BOX}{path}>")) });
            self.m.impls.push((h, name.clone()));
        }
        self.m.traits.push(td);
    }

    /// the declaration as it's written, on one line (a macro's item: where the macro made it)
    fn src(&self, it: &Json, name: &str) -> String {
        let span = it.get("span");
        let file = span.and_then(|s| s.get("filename")).and_then(Json::str).map(|f| self.dir.join(f));
        let line = |k: &str| span.and_then(|s| s.get(k)).map(|b| b.arr()).and_then(|b| b.first()).and_then(Json::key).and_then(|n| n.parse::<usize>().ok());
        let text = file.and_then(|f| std::fs::read_to_string(f).ok());
        let (Some(text), Some(lo), Some(hi)) = (text, line("begin"), line("end")) else { return format!("fn {name}") };
        let lines: Vec<&str> = text.lines().skip(lo.saturating_sub(1)).take(hi + 1 - lo.min(hi)).collect();
        let joined = lines.join(" ");
        // up to its body or its ; (not one inside [T; N])
        let mut depth = 0i32;
        let end = joined.char_indices().find(|&(_, c)| {
            match c {
                '[' | '(' => depth += 1,
                ']' | ')' => depth -= 1,
                _ => {}
            }
            c == '{' || (c == ';' && depth == 0)
        });
        let head = &joined[..end.map_or(joined.len(), |(i, _)| i)];
        head.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    fn typedef(&mut self, module: Vec<String>, name: String, it: &Json, body: &Json, is_enum: bool) {
        let opaque = it.get("attrs").map_or(&[][..], Json::arr).iter().any(|a| a.str() == Some("non_exhaustive") || a.get("other").and_then(Json::str).is_some_and(|s| s.contains("non_exhaustive")));
        let gps = body.get("generics").and_then(|g| g.get("params")).map_or(&[][..], Json::arr);
        // over types only (a const parameter leaves it out)
        let params: Vec<String> = if gps.iter().all(|p| p.get("kind").is_some_and(|k| k.get("type").is_some() || k.get("lifetime").is_some())) { gps.iter().filter(|p| p.get("kind").is_some_and(|k| k.get("type").is_some())).filter_map(|p| p.get("name").and_then(Json::str)).map(String::from).collect() } else { Vec::new() };
        let mut d = TypeDef { module, name: name.clone(), generic: generic(body.get("generics")), fields: None, variants: None, is_enum, clone: false, opaque, params, rust_name: None };
        if let Some(p) = body.get("kind").and_then(|k| k.get("plain")) {
            let mut fields = Vec::new();
            for fid in p.get("fields").map_or(&[][..], Json::arr) {
                let Some(f) = fid.key().and_then(|k| self.idx.get(&k)) else { continue };
                let public = f.get("visibility").and_then(Json::str) == Some("public");
                let ty = f.get("inner").and_then(|i| i.get("struct_field")).and_then(|t| self.ty(t));
                fields.push((f.get("name").and_then(Json::str).unwrap_or("_").to_string(), public, ty));
            }
            // fields rustdoc doesn't show are private
            if p.get("has_stripped_fields").and_then(Json::bool) == Some(true) {
                fields.push(("_".into(), false, None));
            }
            d.fields = Some(fields);
        }
        if is_enum {
            let mut vs = Vec::new();
            let mut next: i128 = 0;
            let mut plain = body.get("has_stripped_variants").and_then(Json::bool) != Some(true);
            for vid in body.get("variants").map_or(&[][..], Json::arr) {
                let Some(v) = vid.key().and_then(|k| self.idx.get(&k)) else { continue };
                let var = v.get("inner").and_then(|i| i.get("variant"));
                if var.and_then(|x| x.get("kind")).and_then(Json::str) != Some("plain") {
                    plain = false;
                }
                if let Some(n) = var.and_then(|x| x.get("discriminant")).and_then(|x| x.get("value")).and_then(Json::str).and_then(|x| int_text(x).parse().ok()) {
                    next = n;
                }
                vs.push((v.get("name").and_then(Json::str).unwrap_or("_").to_string(), next));
                next += 1;
            }
            d.variants = plain.then_some(vs);
        }
        // its impls: Clone, and the inherent ones' pub fns as its methods
        for iid in body.get("impls").map_or(&[][..], Json::arr) {
            let Some(im) = iid.key().and_then(|k| self.idx.get(&k)).and_then(|x| x.get("inner")).and_then(|i| i.get("impl")) else { continue };
            if im.get("blanket_impl").is_some_and(|b| !b.is_null()) || im.get("is_synthetic").and_then(Json::bool) == Some(true) {
                continue;
            }
            match im.get("trait").filter(|t| !t.is_null()) {
                Some(tr) => {
                    if tr.get("path").and_then(Json::str).is_some_and(|p| p.rsplit("::").next() == Some("Clone")) {
                        d.clone = true;
                    }
                }
                None => {
                    for fid in im.get("items").map_or(&[][..], Json::arr) {
                        let Some(f) = fid.key().and_then(|k| self.idx.get(&k)) else { continue };
                        let (Some(func), Some(fname)) = (f.get("inner").and_then(|i| i.get("function")), f.get("name").and_then(Json::str)) else { continue };
                        if f.get("visibility").and_then(Json::str) == Some("public") {
                            let s = self.sig(f, func, fname);
                            self.m.methods.entry(name.clone()).or_default().push(s);
                        }
                    }
                }
            }
        }
        self.m.types.push(d);
    }

    /// a const of a number, bool or string, with the value rustc worked out
    fn constant(&mut self, module: Vec<String>, name: String, c: &Json) {
        let k = c.get("const");
        let value = k.and_then(|k| k.get("value")).and_then(Json::str);
        let expr = k.and_then(|k| k.get("expr")).and_then(Json::str);
        let lit = match c.get("type").and_then(|t| self.ty(t)) {
            Some(Ty::Prim("bool")) => value.or(expr).filter(|v| *v == "true" || *v == "false").map(|v| ("bool".to_string(), v.to_string())),
            Some(Ty::Prim(x)) => value.or(expr).and_then(|v| volt_number(v, x)).map(|v| (x.to_string(), v)),
            Some(Ty::Str) => expr.filter(|e| plain_string(e)).map(|e| ("str".to_string(), e.to_string())),
            _ => None,
        };
        match lit {
            Some((ty, lit)) => self.m.consts.push((module, name, ty, lit)),
            None => self.m.left_out.push(format!("const {name} (not a number, bool or string)")),
        }
    }

    /// a type Volt can name, from rustdoc's form of it
    fn ty(&self, t: &Json) -> Option<Ty> {
        if let Some(p) = t.get("primitive").and_then(Json::str) {
            return if p == "char" { Some(Ty::Char) } else { prim(p).map(Ty::Prim) };
        }
        if let Some(tup) = t.get("tuple") {
            return tup.arr().is_empty().then_some(Ty::Unit);
        }
        if let Some(it) = t.get("impl_trait") {
            return self.fn_bound(Some(it), FnPass::Value).or_else(|| Some(Ty::Dyn(self.trait_bound(Some(it))?, FnPass::Value)));
        }
        if let Some(g) = t.get("generic").and_then(Json::str) {
            return Some(if g == "Self" { Ty::SelfTy } else { Ty::Generic(g.to_string()) });
        }
        if let Some(r) = t.get("borrowed_ref") {
            let mutable = r.get("is_mutable").and_then(Json::bool) == Some(true);
            let inner = r.get("type")?;
            let pass = if mutable { FnPass::MutRef } else { FnPass::Ref };
            if let Some(d) = inner.get("dyn_trait") {
                return self.fn_bound(d.get("traits"), pass).or_else(|| Some(Ty::Dyn(self.trait_bound(d.get("traits"))?, pass)));
            }
            if let Some(it) = inner.get("impl_trait") {
                return self.fn_bound(Some(it), pass).or_else(|| Some(Ty::Dyn(self.trait_bound(Some(it))?, pass)));
            }
            if inner.get("primitive").and_then(Json::str) == Some("str") {
                return (!mutable).then_some(Ty::Str);
            }
            if let Some(e) = inner.get("slice") {
                return Some(Ty::Slice(Box::new(self.ty(e)?), mutable));
            }
            return match self.ty(inner)? {
                Ty::String if !mutable => Some(Ty::Str),
                Ty::Vec(e) => Some(Ty::Slice(e, mutable)),
                x @ (Ty::Named(_) | Ty::SelfTy | Ty::Generic(_)) => Some(Ty::Ref(Box::new(x), mutable)),
                x @ (Ty::Prim(_) | Ty::Char) if !mutable => Some(x),
                _ => None,
            };
        }
        let p = t.get("resolved_path")?;
        let last = p.get("path").and_then(Json::str)?.rsplit("::").next()?.to_string();
        // its type arguments (lifetimes aren't types)
        let args: Vec<&Json> = p.get("args").and_then(|a| a.get("angle_bracketed")).and_then(|a| a.get("args")).map_or(Vec::new(), |a| a.arr().iter().filter_map(|x| x.get("type")).collect());
        let one = || -> Option<Box<Ty>> { Some(Box::new(self.ty(args.first()?)?)) };
        if last == "Box" && args.len() == 1 {
            if let Some(d) = args[0].get("dyn_trait") {
                return self.fn_bound(d.get("traits"), FnPass::Boxed).or_else(|| Some(Ty::Dyn(self.trait_bound(d.get("traits"))?, FnPass::Boxed)));
            }
        }
        if let Some(local) = p.get("id").and_then(Json::key).and_then(|id| self.names.get(&id)) {
            // a generic type over type parameters (Stack<T> in its own impl): each instance's
            // methods name the instance
            return (args.is_empty() || args.iter().all(|a| a.get("generic").is_some())).then(|| Ty::Named(local.clone()));
        }
        // another crate's type named like one of this crate's (std::io::Error next to an Error)
        let shadowed = self.names.values().any(|n| *n == last);
        match (last.as_str(), args.len()) {
            ("String", 0) => Some(Ty::String),
            ("Vec", 1) => Some(Ty::Vec(one()?)),
            ("Option", 1) => Some(Ty::Opt(one()?)),
            ("Result", 1 | 2) => Some(Ty::Res(one()?)),
            (_, 0) if !shadowed && last.starts_with(|c: char| c.is_ascii_uppercase()) => Some(Ty::Named(last)),
            _ => None,
        }
    }
}

/// whether generics hold type or const parameters (lifetimes don't count)
fn generic(g: Option<&Json>) -> bool {
    g.and_then(|g| g.get("params")).map_or(&[][..], Json::arr).iter().any(|p| p.get("kind").is_some_and(|k| k.get("lifetime").is_none()))
}

/// a number rustdoc wrote (42i32, -5i64, 1_000usize, 0.5f64) without its type suffix (a hex
/// literal's f32 is digits)
fn int_text(v: &str) -> String {
    let v = v.replace('_', "");
    let hex = v.trim_start_matches('-').starts_with("0x");
    for s in ["usize", "isize", "u128", "i128", "u64", "i64", "u32", "i32", "u16", "i16", "u8", "i8", "f64", "f32"] {
        if hex && s.starts_with('f') {
            continue;
        }
        if let Some(x) = v.strip_suffix(s) {
            return x.to_string();
        }
    }
    v
}

/// one string literal with no escapes but \\ \" \n \t \r (which Volt writes the same)
fn plain_string(e: &str) -> bool {
    let Some(body) = e.strip_prefix('"').and_then(|b| b.strip_suffix('"')) else { return false };
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return false,
            '\\' => {
                if !matches!(chars.next(), Some('\\' | '"' | 'n' | 't' | 'r')) {
                    return false;
                }
            }
            _ => {}
        }
    }
    true
}

/// whether an item is under a #[cfg] that names doc (rustdoc's own cfg)
fn under_cfg_doc(it: &Json) -> bool {
    it.get("attrs").map_or(&[][..], Json::arr).iter().any(|a| a.get("other").and_then(Json::str).is_some_and(|s| s.contains("CfgTrace") && s.contains("name: \"doc\"")))
}

/// a number rustdoc wrote as a Volt literal of type x (None for what Volt can't write: inf, NaN)
fn volt_number(v: &str, x: &str) -> Option<String> {
    let n = int_text(v);
    if x.starts_with('f') {
        let f: f64 = n.parse().ok()?;
        if !f.is_finite() {
            return None;
        }
        return Some(if n.contains(['.', 'e', 'E']) { n } else { format!("{n}.0") });
    }
    let parsed = match n.strip_prefix("0x") {
        Some(h) => i128::from_str_radix(h, 16).ok(),
        None => n.parse::<i128>().ok(),
    };
    parsed.map(|_| n)
}

// ---------- the crate's public API, read from its source (when rustdoc's JSON isn't there) ----------

/// what the walk finds; derives and trait impls decide which types are Clone
#[derive(Default)]
struct Walker {
    m: Model,
    derives: BTreeMap<String, BTreeSet<String>>,
    traits: BTreeMap<String, BTreeSet<String>>,
}

impl Walker {
    fn model(mut self) -> Model {
        for t in &mut self.m.types {
            t.clone = self.derives.get(&t.name).is_some_and(|d| d.contains("Clone")) || self.traits.get(&t.name).is_some_and(|d| d.contains("Clone"));
        }
        self.m
    }

    /// a file's (or an inline mod's) items: `dir` is where its child modules' files are
    fn walk(&mut self, t: &[Tok], module: &[String], dir: &Path) {
        let mut c = Cur { t, i: 0 };
        let mut attrs: Vec<Vec<Tok>> = Vec::new();
        while c.i < t.len() {
            if c.is("#") {
                c.i += 1;
                let inner = c.eat("!");
                if c.is("[") {
                    let s = c.i;
                    c.skip_group();
                    if !inner {
                        attrs.push(t[s + 1..c.i - 1].to_vec());
                    }
                }
                continue;
            }
            let start = c.i;
            let kind = item_kind(&t[start..]);
            let mut body = None;
            while c.i < t.len() {
                if c.is(";") {
                    c.i += 1;
                    break;
                }
                if c.is("{") && !matches!(kind, "const" | "static") {
                    let s = c.i;
                    c.skip_group();
                    body = Some((s + 1, c.i - 1));
                    break;
                }
                if c.is("(") || c.is("[") || c.is("{") {
                    c.skip_group();
                    continue;
                }
                c.i += 1;
            }
            let item = &t[start..c.i];
            let cfg = attrs.iter().any(|a| matches!(a.first(), Some(Tok::Id(w)) if w == "cfg"));
            if !cfg {
                self.item(&attrs, item, kind, body.map(|(a, b)| &t[a..b]), module, dir);
            }
            attrs.clear();
        }
    }

    fn item(&mut self, attrs: &[Vec<Tok>], item: &[Tok], kind: &str, body: Option<&[Tok]>, module: &[String], dir: &Path) {
        let public = is_pub(item);
        let at = |w: &str| item.iter().position(|x| matches!(x, Tok::Id(y) if y == w));
        match kind {
            "mod" if public => {
                let Some(Tok::Id(name)) = at("mod").and_then(|k| item.get(k + 1)) else { return };
                let mut sub = module.to_vec();
                sub.push(name.clone());
                match body {
                    Some(b) => self.walk(b, &sub, &dir.join(name)),
                    None => {
                        let file = [dir.join(format!("{name}.rs")), dir.join(name).join("mod.rs")].into_iter().find(|p| p.is_file());
                        if let Some(text) = file.and_then(|f| std::fs::read_to_string(f).ok()) {
                            self.walk(&lex(&text), &sub, &dir.join(name));
                        }
                    }
                }
            }
            "fn" if public => self.m.fns.push((module.to_vec(), sig(item))),
            "struct" | "enum" if public => {
                let Some(k) = at(kind) else { return };
                let Some(Tok::Id(name)) = item.get(k + 1) else { return };
                let generic = matches!(item.get(k + 2), Some(Tok::P(p)) if p == "<") && generic_args(item, k + 2);
                let opaque = attrs.iter().any(|a| matches!(a.first(), Some(Tok::Id(w)) if w == "non_exhaustive"));
                let mut d = TypeDef { module: module.to_vec(), name: name.clone(), generic, fields: None, variants: None, is_enum: kind == "enum", clone: false, opaque, params: Vec::new(), rust_name: None };
                let open = item.iter().position(|x| *x == Tok::P("{".into()));
                if kind == "struct" {
                    if let Some(open) = open {
                        let mut fc = Cur { t: item, i: open };
                        let mut fields = Vec::new();
                        for f in fc.group_items() {
                            let f = strip_attrs(&f);
                            let Some(colon) = f.iter().position(|x| *x == Tok::P(":".into())) else { continue };
                            let Some(Tok::Id(fname)) = f.get(colon - 1) else { continue };
                            fields.push((fname.clone(), is_pub(&f), parse_ty(&f[colon + 1..])));
                        }
                        d.fields = Some(fields);
                    }
                } else if let Some(open) = open {
                    let mut vc = Cur { t: item, i: open };
                    let mut vs = Vec::new();
                    let mut next: i128 = 0;
                    let mut plain = true;
                    for v in vc.group_items() {
                        let v = strip_attrs(&v);
                        let Some(Tok::Id(vn)) = v.first() else { continue };
                        if v.iter().any(|x| matches!(x, Tok::P(p) if p == "(" || p == "{")) {
                            plain = false;
                        }
                        if let Some(eq) = v.iter().position(|x| *x == Tok::P("=".into())) {
                            next = int_value(&v[eq + 1..]).unwrap_or(next);
                        }
                        vs.push((vn.clone(), next));
                        next += 1;
                    }
                    d.variants = plain.then_some(vs);
                }
                self.derives.insert(name.clone(), derives(attrs));
                self.m.types.push(d);
            }
            "const" if public => {
                let Some(k) = at("const") else { return };
                let (Some(Tok::Id(name)), Some(colon), Some(eq)) = (item.get(k + 1), item.iter().position(|x| *x == Tok::P(":".into())), item.iter().position(|x| *x == Tok::P("=".into()))) else { return };
                let end = item.len() - usize::from(item.last() == Some(&Tok::P(";".into())));
                match literal(parse_ty(&item[colon + 1..eq]), &item[eq + 1..end]) {
                    Some((ty, lit)) => self.m.consts.push((module.to_vec(), name.clone(), ty, lit)),
                    None => self.m.left_out.push(format!("const {name} (not a number, bool or string literal)")),
                }
            }
            "impl" => {
                let Some(b) = body else { return };
                // impl<...> [Trait for] Type<...>
                let mut i = at("impl").unwrap_or(0) + 1;
                if matches!(item.get(i), Some(Tok::P(p)) if p == "<") {
                    let mut gc = Cur { t: item, i };
                    gc.skip_group();
                    i = gc.i;
                }
                let head: Vec<Tok> = item[i..].iter().take_while(|x| **x != Tok::P("{".into()) && **x != Tok::Id("where".into())).cloned().collect();
                let (trait_name, ty) = match head.iter().position(|x| *x == Tok::Id("for".into())) {
                    Some(f) => (last_ident(&head[..f]), head[f + 1..].to_vec()),
                    None => (None, head.clone()),
                };
                let Some(ty_name) = last_ident(&ty) else { return };
                if let Some(tr) = trait_name {
                    self.traits.entry(ty_name).or_default().insert(tr);
                    return;
                }
                // the impl's pub fns
                let mut ic = Cur { t: b, i: 0 };
                while ic.i < b.len() {
                    if ic.is("#") {
                        ic.i += 1;
                        if ic.is("[") {
                            ic.skip_group();
                        }
                        continue;
                    }
                    let s = ic.i;
                    while ic.i < b.len() {
                        if ic.is(";") {
                            ic.i += 1;
                            break;
                        }
                        if ic.is("{") {
                            ic.skip_group();
                            break;
                        }
                        if ic.is("(") || ic.is("[") {
                            ic.skip_group();
                            continue;
                        }
                        ic.i += 1;
                    }
                    let f = &b[s..ic.i];
                    if is_pub(f) && item_kind(f) == "fn" {
                        self.m.methods.entry(ty_name.clone()).or_default().push(sig(f));
                    }
                }
            }
            _ => {}
        }
    }
}

/// `pub`, not `pub(crate)` and the like
fn is_pub(t: &[Tok]) -> bool {
    matches!(t.first(), Some(Tok::Id(w)) if w == "pub") && !matches!(t.get(1), Some(Tok::P(p)) if p == "(")
}

/// a const's Volt type and literal, when its value is a literal Volt can write
fn literal(t: Option<Ty>, value: &[Tok]) -> Option<(String, String)> {
    match (t?, value) {
        (Ty::Prim(x), v) if x != "bool" && number(v).is_some_and(|n| x.starts_with('f') || !n.1) => Some((x.to_string(), number(v)?.0)),
        (Ty::Prim("bool"), [Tok::Id(b)]) if b == "true" || b == "false" => Some(("bool".into(), b.clone())),
        (Ty::Str, [Tok::Str(s)]) => Some(("str".into(), format!("\"{s}\""))),
        _ => None,
    }
}

/// the kind of item these tokens start: fn, struct, enum, mod, impl, const, static, use, trait, ...
fn item_kind(t: &[Tok]) -> &'static str {
    const KINDS: &[&str] = &["fn", "struct", "enum", "mod", "impl", "const", "static", "use", "trait", "type", "union", "macro_rules", "extern"];
    for x in t.iter().take(8) {
        match x {
            Tok::Id(w) => {
                if let Some(k) = KINDS.iter().find(|k| **k == w) {
                    // `const fn` and `extern "C" fn` are fns
                    if (*k == "const" || *k == "extern") && t.iter().take(8).any(|y| *y == Tok::Id("fn".into())) {
                        return "fn";
                    }
                    return k;
                }
            }
            Tok::P(p) if p == "{" || p == ";" => break,
            _ => {}
        }
    }
    ""
}

/// whether the <...> at i holds generic parameters (lifetimes, which the lexer drops, don't count)
fn generic_args(t: &[Tok], i: usize) -> bool {
    let mut c = Cur { t, i };
    c.group_items().iter().any(|x| !x.is_empty())
}

fn strip_attrs(t: &[Tok]) -> Vec<Tok> {
    let mut c = Cur { t, i: 0 };
    while c.is("#") {
        c.i += 1;
        c.skip_group();
    }
    t[c.i..].to_vec()
}

/// a type's name: the last identifier before any <...>
fn last_ident(t: &[Tok]) -> Option<String> {
    let end = t.iter().position(|x| *x == Tok::P("<".into())).unwrap_or(t.len());
    t[..end].iter().rev().find_map(|x| if let Tok::Id(w) = x { Some(w.clone()) } else { None })
}

/// #[derive(Clone, Copy, ...)]'s names
fn derives(attrs: &[Vec<Tok>]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for a in attrs {
        if matches!(a.first(), Some(Tok::Id(w)) if w == "derive") {
            for x in a {
                if let Tok::Id(w) = x {
                    out.insert(w.clone());
                }
            }
        }
    }
    out
}

/// a fn's signature from its tokens
fn sig(item: &[Tok]) -> Sig {
    let k = item.iter().position(|x| *x == Tok::Id("fn".into())).unwrap_or(0);
    let name = match item.get(k + 1) {
        Some(Tok::Id(n)) => n.clone(),
        _ => String::new(),
    };
    let head = item.iter().position(|x| matches!(x, Tok::P(p) if p == "{" || p == ";")).unwrap_or(item.len());
    let mut s = Sig { name, recv: Recv::None, params: Vec::new(), ret: Some(Ty::Unit), skip: None, src: toks_line(&item[..head]), generics: Vec::new(), call: None };
    if item[..k].iter().any(|x| *x == Tok::Id("async".into())) {
        s.skip = Some("it's async");
    }
    let mut c = Cur { t: item, i: k + 2 };
    if c.is("<") {
        if generic_args(item, c.i) {
            s.skip = Some("it's generic");
        }
        c.skip_group();
    }
    if !c.is("(") {
        s.skip = Some("its parameters");
        return s;
    }
    for (n, p) in c.group_items().into_iter().enumerate() {
        let mut p = strip_attrs(&p);
        let words: Vec<String> = p.iter().map(tok_text).collect();
        let w: Vec<&str> = words.iter().map(String::as_str).collect();
        if n == 0 && w.contains(&"self") {
            s.recv = match w.as_slice() {
                ["&", "self"] | ["self", ":", "&", "Self"] => Recv::Ref,
                ["&", "mut", "self"] | ["self", ":", "&", "mut", "Self"] => Recv::Mut,
                ["self"] | ["mut", "self"] | ["self", ":", "Self"] | ["mut", "self", ":", "Self"] => Recv::Value,
                _ => {
                    s.skip = Some("its self parameter");
                    Recv::None
                }
            };
            continue;
        }
        // `mut x: T`: the binding's mut is the callee's business
        if p.first() == Some(&Tok::Id("mut".into())) {
            p.remove(0);
        }
        let Some(colon) = p.iter().position(|x| *x == Tok::P(":".into())) else {
            s.skip = Some("a parameter");
            continue;
        };
        let pname = match p.first() {
            Some(Tok::Id(x)) if colon == 1 && x != "_" => x.clone(),
            _ => format!("a{n}"),
        };
        s.params.push((pname, parse_ty(&p[colon + 1..])));
    }
    if c.eat("->") {
        let st = c.i;
        while c.i < item.len() && !c.is("{") && !c.is(";") && !c.is_id("where") {
            c.i += 1;
        }
        s.ret = parse_ty(&item[st..c.i]);
    }
    if c.is_id("where") {
        s.skip = Some("it has a where clause");
    }
    s
}

/// a Rust type from its tokens, when it's one Volt can name
fn parse_ty(t: &[Tok]) -> Option<Ty> {
    match t {
        [] => Some(Ty::Unit),
        [Tok::P(a), Tok::P(b)] if a == "(" && b == ")" => Some(Ty::Unit),
        [Tok::P(amp), rest @ ..] if amp == "&" => {
            let (mutable, rest) = match rest {
                [Tok::Id(m), rest @ ..] if m == "mut" => (true, rest),
                _ => (false, rest),
            };
            match rest {
                [Tok::Id(s)] if s == "str" && !mutable => Some(Ty::Str),
                [Tok::P(o), inner @ .., Tok::P(c)] if o == "[" && c == "]" => Some(Ty::Slice(Box::new(parse_ty(inner)?), mutable)),
                _ => match parse_ty(rest)? {
                    Ty::String if !mutable => Some(Ty::Str),
                    Ty::Vec(e) => Some(Ty::Slice(e, mutable)),
                    t @ (Ty::Named(_) | Ty::SelfTy) => Some(Ty::Ref(Box::new(t), mutable)),
                    t @ (Ty::Prim(_) | Ty::Char) if !mutable => Some(t),
                    _ => None,
                },
            }
        }
        _ => {
            // a path, maybe with <args> at its end
            let lt = t.iter().position(|x| *x == Tok::P("<".into()));
            let path = &t[..lt.unwrap_or(t.len())];
            if path.iter().any(|x| matches!(x, Tok::P(p) if p != "::")) {
                return None;
            }
            let Some(Tok::Id(name)) = path.last() else { return None };
            let args = match lt {
                Some(i) => {
                    if t.last() != Some(&Tok::P(">".into())) {
                        return None;
                    }
                    let mut c = Cur { t, i };
                    c.group_items()
                }
                None => Vec::new(),
            };
            let one = |args: &[Vec<Tok>]| -> Option<Box<Ty>> { Some(Box::new(parse_ty(args.first()?)?)) };
            match (name.as_str(), args.len()) {
                (p, 0) if prim(p).is_some() => Some(Ty::Prim(prim(p)?)),
                ("char", 0) => Some(Ty::Char),
                ("String", 0) => Some(Ty::String),
                ("Self", 0) => Some(Ty::SelfTy),
                ("Vec", 1) => Some(Ty::Vec(one(&args)?)),
                ("Option", 1) => Some(Ty::Opt(one(&args)?)),
                ("Result", 1 | 2) => Some(Ty::Res(one(&args)?)),
                (_, 0) if name.chars().next().is_some_and(|c| c.is_ascii_uppercase()) => Some(Ty::Named(name.clone())),
                _ => None,
            }
        }
    }
}

// ---------- the shim, in Rust ----------

struct Rust {
    lib: String,
}

/// a trait object's handle holds a Box<dyn Trait> (its type's rust_name: this, the trait's path, >)
const DYN_BOX: &str = "::std::boxed::Box<dyn ";

impl Rust {
    /// the Rust path of a named type, from the shim
    fn path(&self, def: &TypeDef) -> String {
        if let Some(r) = def.rust_name.as_ref().filter(|r| r.starts_with("::")) {
            return r.clone();
        }
        let mut p = vec![self.lib.clone()];
        p.extend(def.module.iter().cloned());
        p.push(def.rust_name.clone().unwrap_or_else(|| def.name.clone()));
        format!("::{}", p.join("::"))
    }

    /// a trait's Rust path, from the shim
    fn trait_path(&self, t: &TraitDef) -> String {
        let mut p = vec![self.lib.clone()];
        p.extend(t.module.iter().cloned());
        p.push(t.name.clone());
        format!("::{}", p.join("::"))
    }
}

impl Lang for Rust {
    fn short(&self) -> &'static str {
        "rust"
    }

    fn name(&self) -> &'static str {
        "Rust"
    }

    fn by_value_moves(&self, _ti: &TypeInfo) -> bool {
        true
    }

    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam> {
        let mut p = ShimParam::default();
        match t {
            Ty::Prim(x) => {
                p.params.push(format!("{a}: {x}"));
                p.arg = a.to_string();
            }
            Ty::Char => {
                p.params.push(format!("{a}: u32"));
                p.arg = format!("char::from_u32({a}).unwrap_or('\\u{{fffd}}')");
            }
            Ty::Ref(x, false) if matches!(**x, Ty::Prim(_)) => {
                let Ty::Prim(x) = **x else { return None };
                p.params.push(format!("{a}: {x}"));
                p.arg = format!("&{a}");
            }
            // a Volt closure: its trampoline and the closure (the trampoline's data), made a Rust
            // closure that calls them, passed the way the fn takes it
            Ty::Fn(ps, r, pass, _) => {
                let mut cps = vec!["*mut c_void".to_string()];
                let mut binds = Vec::new();
                let mut args = vec![format!("{a}_env")];
                for (i, t) in ps.iter().enumerate() {
                    match t {
                        Ty::Prim(x) => {
                            cps.push(x.to_string());
                            binds.push(format!("x{i}: {x}"));
                            args.push(format!("x{i}"));
                        }
                        Ty::Char => {
                            cps.push("u32".into());
                            binds.push(format!("x{i}: char"));
                            args.push(format!("x{i} as u32"));
                        }
                        Ty::Str | Ty::String => {
                            cps.extend(["*const u8".to_string(), "usize".to_string()]);
                            binds.push(format!("x{i}: {}", if *t == Ty::Str { "&str" } else { "String" }));
                            args.extend([format!("x{i}.as_ptr()"), format!("x{i}.len()")]);
                        }
                        _ => return None,
                    }
                }
                let (cret, wrap) = match &**r {
                    Ty::Unit => (String::new(), ("", "")),
                    Ty::Prim(x) => (format!(" -> {x}"), ("", "")),
                    Ty::Char => (" -> u32".to_string(), ("char::from_u32(", ").unwrap_or('\\u{fffd}')")),
                    // a String: Volt puts it where o points
                    Ty::String => {
                        cps.push("*mut c_void".into());
                        args.push("&mut o as *mut String as *mut c_void".into());
                        (String::new(), ("{ let mut o = String::new(); ", "; o }"))
                    }
                    _ => return None,
                };
                p.params.extend([format!("{a}: extern \"C\" fn({}){cret}", cps.join(", ")), format!("{a}_env: *mut c_void")]);
                let clo = if matches!(pass, FnPass::Value | FnPass::Boxed) {
                    // owned: the closure holds Volt's value (g, whole: not just its env field) and
                    // drops it with itself
                    p.params.push(format!("{a}_drop: Option<unsafe extern \"C\" fn(*mut c_void)>"));
                    args[0] = "g.env".into();
                    format!("{{ let g = VoltEnv {{ env: {a}_env, drop: {a}_drop }}; move |{}| {{ let g = &g; {}{a}({}){} }} }}", binds.join(", "), wrap.0, args.join(", "), wrap.1)
                } else {
                    format!("move |{}| {}{a}({}){}", binds.join(", "), wrap.0, args.join(", "), wrap.1)
                };
                p.arg = match pass {
                    FnPass::Value => clo,
                    FnPass::Ref => format!("&{clo}"),
                    FnPass::MutRef => format!("&mut {clo}"),
                    FnPass::Boxed => format!("Box::new({clo})"),
                };
            }
            // a Volt value and its methods' table: a Volt_T, which implements the trait
            Ty::Dyn(tr, pass) => {
                let mg = Gen::trait_mangle(g.traits.get(tr)?);
                p.params.extend([format!("{a}: *mut c_void"), format!("{a}_t: *const VT_{mg}")]);
                let v = format!("Volt_{mg} {{ env: {a}, t: *{a}_t }}");
                p.arg = match pass {
                    FnPass::Value => v,
                    FnPass::Ref => format!("&{v}"),
                    FnPass::MutRef => format!("&mut {v}"),
                    FnPass::Boxed => format!("Box::new({v})"),
                };
            }
            Ty::Str | Ty::String => {
                p.params.extend([format!("{a}: *const u8"), format!("{a}_n: usize")]);
                p.arg = if *t == Ty::String { format!("s({a}, {a}_n).to_string()") } else { format!("s({a}, {a}_n)") };
            }
            Ty::Slice(e, _) | Ty::Vec(e) if matches!(**e, Ty::Prim(_)) => {
                let Ty::Prim(x) = **e else { return None };
                if matches!(t, Ty::Slice(_, true)) {
                    p.params.extend([format!("{a}: *mut {x}"), format!("{a}_n: usize")]);
                    p.arg = format!("slm({a}, {a}_n)");
                } else {
                    p.params.extend([format!("{a}: *const {x}"), format!("{a}_n: usize")]);
                    p.arg = if matches!(t, Ty::Vec(_)) { format!("sl({a}, {a}_n).to_vec()") } else { format!("sl({a}, {a}_n)") };
                }
            }
            Ty::Slice(e, false) | Ty::Vec(e) if matches!(**e, Ty::Str | Ty::String) => {
                p.params.extend([format!("{a}: *const VoltStr"), format!("{a}_n: usize")]);
                p.arg = match (t, &**e) {
                    (Ty::Vec(_), _) => format!("strs({a}, {a}_n).into_iter().map(String::from).collect()"),
                    (_, Ty::String) => format!("&strs({a}, {a}_n).into_iter().map(String::from).collect::<Vec<String>>()"),
                    _ => format!("&strs({a}, {a}_n)"),
                };
            }
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    p.params.extend([format!("{a}_has: bool"), format!("{a}: {x}")]);
                    p.arg = format!("if {a}_has {{ Some({a}) }} else {{ None }}");
                }
                Ty::Str | Ty::String => {
                    p.params.extend([format!("{a}: *const u8"), format!("{a}_n: usize")]);
                    let conv = if **inner == Ty::String { ".to_string()" } else { "" };
                    p.arg = format!("if {a}.is_null() {{ None }} else {{ Some(s({a}, {a}_n){conv}) }}");
                }
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref, mutable) = match t {
                    Ty::Ref(x, m) => (&**x, true, *m),
                    x => (x, false, false),
                };
                let ti = g.info(named)?;
                let (rp, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => {
                        p.params.push(format!("{a}: *mut V_{mg}"));
                        if mutable {
                            p.pre.push(format!("let mut {a}_v = from_{mg}(&*{a});"));
                            p.arg = format!("&mut {a}_v");
                            p.post.push(format!("*{a} = to_{mg}(&{a}_v);"));
                        } else {
                            p.arg = if by_ref { format!("&from_{mg}(&*{a})") } else { format!("from_{mg}(&*{a})") };
                        }
                    }
                    Kind::Handle => {
                        p.params.push(format!("{a}: *mut c_void"));
                        p.arg = match (by_ref, mutable) {
                            (true, true) => format!("&mut *({a} as *mut {rp})"),
                            (true, false) => format!("&*({a} as *const {rp})"),
                            _ => format!("*Box::from_raw({a} as *mut {rp})"),
                        };
                    }
                    Kind::Enum => {
                        if mutable {
                            return None;
                        }
                        p.params.push(format!("{a}: i64"));
                        p.arg = if by_ref { format!("&from_{mg}({a})") } else { format!("from_{mg}({a})") };
                    }
                }
            }
            _ => return None,
        }
        Some(p)
    }

    fn receiver(&self, _g: &Gen, ti: &TypeInfo, recv: Recv) -> Option<ShimParam> {
        let (rp, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
        let mut p = ShimParam::default();
        match ti.kind {
            Kind::Plain => {
                p.params.push(format!("this: *mut V_{mg}"));
                match recv {
                    Recv::Mut => {
                        p.pre.push(format!("let mut this_v = from_{mg}(&*this);"));
                        p.arg = "(&mut this_v)".into();
                        p.post.push(format!("*this = to_{mg}(&this_v);"));
                    }
                    // bound, not a temporary: a trait method's lent text outlives the call
                    // (a Plain type has only numbers, so that text can only be 'static)
                    Recv::Ref => {
                        p.pre.push(format!("let this_v = from_{mg}(&*this);"));
                        p.arg = "(&this_v)".into();
                    }
                    _ => p.arg = format!("from_{mg}(&*this)"),
                }
            }
            // a trait object's: the object, not its box
            Kind::Handle if rp.starts_with(DYN_BOX) => {
                p.params.push("this: *mut c_void".into());
                p.arg = match recv {
                    Recv::Mut => format!("(&mut **(this as *mut {rp}))"),
                    Recv::Ref => format!("(&**(this as *const {rp}))"),
                    _ => return None,
                };
            }
            Kind::Handle => {
                p.params.push("this: *mut c_void".into());
                p.arg = match recv {
                    Recv::Mut => format!("(&mut *(this as *mut {rp}))"),
                    Recv::Ref => format!("(&*(this as *const {rp}))"),
                    _ => format!("(*Box::from_raw(this as *mut {rp}))"),
                };
            }
            Kind::Enum => {
                if recv == Recv::Mut {
                    return None;
                }
                p.params.push("this: i64".into());
                p.arg = if recv == Recv::Ref { format!("(&from_{mg}(this))") } else { format!("from_{mg}(this)") };
            }
        }
        Some(p)
    }

    fn out(&self, g: &Gen, t: &Ty, o: &str, owned: bool) -> Option<ShimOut> {
        Some(match t {
            Ty::Prim(x) => ShimOut { params: vec![format!("{o}: *mut {x}")], store: format!("*{o} = $v;") },
            Ty::Char => ShimOut { params: vec![format!("{o}: *mut u32")], store: format!("*{o} = $v as u32;") },
            Ty::Fn(ps, r, _, once) => {
                let held = held_fn(ps, r, *once)?;
                let boxed = if *once { format!("Some(Box::new($v) as Box<{}>)", dyn_fn(ps, r, true)?) } else { format!("Box::new($v) as {held}") };
                ShimOut { params: vec![format!("{o}: *mut *mut c_void")], store: format!("*{o} = Box::into_raw(Box::new({boxed})) as *mut c_void;") }
            }
            Ty::Dyn(tr, pass @ (FnPass::Value | FnPass::Boxed)) => {
                let tp = self.trait_path(g.traits.get(tr)?);
                let b = if *pass == FnPass::Boxed { format!("$v as Box<dyn {tp}>") } else { format!("Box::new($v) as Box<dyn {tp}>") };
                ShimOut { params: vec![format!("{o}: *mut *mut c_void")], store: format!("*{o} = Box::into_raw(Box::new({b})) as *mut c_void;") }
            }
            // lent text: where it is (a Plain receiver's text can only be 'static)
            Ty::StrRef => ShimOut { params: vec![format!("{o}: *mut *mut u8"), format!("{o}_n: *mut usize")], store: format!("{{ let w: &str = $v; *{o} = w.as_ptr() as *mut u8; *{o}_n = w.len(); }}") },
            Ty::Str | Ty::String => ShimOut { params: vec![format!("{o}: *mut *mut u8"), format!("{o}_n: *mut usize")], store: format!("put_str($v.to_string(), {o}, {o}_n);") },
            Ty::Slice(e, _) | Ty::Vec(e) => match **e {
                Ty::Prim(x) => ShimOut { params: vec![format!("{o}: *mut *mut {x}"), format!("{o}_n: *mut usize")], store: format!("put_vec($v.to_vec(), {o}, {o}_n);") },
                Ty::Str | Ty::String => ShimOut { params: vec![format!("{o}: *mut *mut VoltOwnedStr"), format!("{o}_n: *mut usize")], store: format!("put_strs($v.iter().map(|x| x.to_string()).collect(), {o}, {o}_n);") },
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref) = match t {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = g.info(named)?;
                let (rp, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => ShimOut { params: vec![format!("{o}: *mut V_{mg}")], store: format!("*{o} = to_{mg}(&$v);") },
                    // a reference into Rust-owned data can't be handed out; a clone can
                    Kind::Handle if by_ref && !ti.def.clone => return None,
                    Kind::Handle if by_ref => ShimOut { params: vec![format!("{o}: *mut *mut c_void")], store: format!("*{o} = Box::into_raw(Box::new(<{rp} as Clone>::clone($v))) as *mut c_void;") },
                    Kind::Handle => ShimOut { params: vec![format!("{o}: *mut *mut c_void")], store: format!("*{o} = Box::into_raw(Box::new($v)) as *mut c_void;") },
                    Kind::Enum => ShimOut { params: vec![format!("{o}: *mut i64")], store: format!("*{o} = to_{mg}(&$v);") },
                }
            }
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, owned)?;
                let mut params = vec![format!("{o}_has: *mut bool")];
                params.extend(x.params);
                ShimOut { params, store: format!("match $v {{ Some(w) => {{ *{o}_has = true; {} }} None => *{o}_has = false }}", x.store.replace("$v", "w")) }
            }
            _ => return None,
        })
    }

    fn fn_glue(&self, _g: &Gen, sym: &str, ps: &[Ty], r: &Ty, once: bool) -> Option<String> {
        let held = held_fn(ps, r, once)?;
        let mut cps = vec!["h: *mut c_void".to_string()];
        let mut args = Vec::new();
        for (i, t) in ps.iter().enumerate() {
            match t {
                Ty::Prim(x) => {
                    cps.push(format!("a{i}: {x}"));
                    args.push(format!("a{i}"));
                }
                Ty::Char => {
                    cps.push(format!("a{i}: u32"));
                    args.push(format!("char::from_u32(a{i}).unwrap_or('\\u{{fffd}}')"));
                }
                Ty::Str => {
                    cps.extend([format!("a{i}: *const u8"), format!("a{i}_n: usize")]);
                    args.push(format!("s(a{i}, a{i}_n)"));
                }
                Ty::String => {
                    cps.extend([format!("a{i}: *const u8"), format!("a{i}_n: usize")]);
                    args.push(format!("s(a{i}, a{i}_n).to_string()"));
                }
                _ => return None,
            }
        }
        let store = match r {
            Ty::String => {
                cps.extend(["o: *mut *mut u8".to_string(), "o_n: *mut usize".to_string()]);
                "put_str(v, o, o_n);".to_string()
            }
            Ty::Unit => String::new(),
            Ty::Prim(x) => {
                cps.push(format!("o: *mut {x}"));
                "*o = v;".to_string()
            }
            Ty::Char => {
                cps.push("o: *mut u32".into());
                "*o = v as u32;".to_string()
            }
            _ => return None,
        };
        let get = if once {
            format!("let f = (*(h as *mut {held})).take().expect(\"a FnOnce closure called twice\");")
        } else {
            format!("let f = &mut *(h as *mut {held});")
        };
        Some(format!("#[no_mangle]\npub unsafe extern \"C\" fn {sym}_call({}) {{\n    {get}\n    let v = f({});\n    let _ = &v;\n    {store}\n}}\n\n#[no_mangle]\npub unsafe extern \"C\" fn {sym}_drop(h: *mut c_void) {{\n    drop(Box::from_raw(h as *mut {held}));\n}}\n\n", cps.join(", "), args.join(", ")))
    }

    fn put_glue(&self, sym: &str) -> Option<String> {
        Some(format!("// a String a Volt function gives back, put where o points\n#[no_mangle]\npub unsafe extern \"C\" fn {sym}(o: *mut c_void, p: *const u8, n: usize) {{\n    *(o as *mut String) = s(p, n).to_string();\n}}\n\n"))
    }

    fn trait_glue(&self, _g: &Gen, t: &TraitDef, ms: &[(Sig, bool)]) -> Option<String> {
        let (tp, mg) = (self.trait_path(t), Gen::trait_mangle(t));
        let mut out = String::new();
        let mut fields = vec!["    drop: Option<unsafe extern \"C\" fn(*mut c_void)>,".to_string()];
        let (mut imp, mut def) = (String::new(), String::new());
        let mut provided_any = false;
        for (s, provided) in ms {
            let n = &s.name;
            let mut cps = vec!["*mut c_void".to_string()];
            let mut rps = vec![if s.recv == Recv::Mut { "&mut self" } else { "&self" }.to_string()];
            let mut args = vec!["self.env".to_string()];
            let mut names = Vec::new();
            for (i, (_, t)) in s.params.iter().enumerate() {
                names.push(format!("a{i}"));
                match t.as_ref()? {
                    Ty::Prim(x) => {
                        cps.push(x.to_string());
                        rps.push(format!("a{i}: {x}"));
                        args.push(format!("a{i}"));
                    }
                    Ty::Char => {
                        cps.push("u32".into());
                        rps.push(format!("a{i}: char"));
                        args.push(format!("a{i} as u32"));
                    }
                    x @ (Ty::Str | Ty::String) => {
                        cps.extend(["*const u8".to_string(), "usize".to_string()]);
                        rps.push(format!("a{i}: {}", if *x == Ty::Str { "&str" } else { "String" }));
                        args.extend([format!("a{i}.as_ptr()"), format!("a{i}.len()")]);
                    }
                    _ => return None,
                }
            }
            let (rret, pre, value) = match s.ret.as_ref()? {
                Ty::Unit => (String::new(), String::new(), String::new()),
                Ty::Prim(x) => {
                    cps.push(format!("*mut {x}"));
                    args.push("&mut o".into());
                    (format!(" -> {x}"), format!("let mut o: {x} = Default::default(); "), " o".to_string())
                }
                Ty::Char => {
                    cps.push("*mut u32".into());
                    args.push("&mut o".into());
                    (" -> char".to_string(), "let mut o: u32 = 0; ".to_string(), " char::from_u32(o).unwrap_or('\\u{fffd}')".to_string())
                }
                Ty::Str => {
                    cps.extend(["*mut *const u8".to_string(), "*mut usize".to_string()]);
                    args.extend(["&mut o".to_string(), "&mut o_n".to_string()]);
                    (" -> &str".to_string(), "let mut o: *const u8 = std::ptr::null(); let mut o_n: usize = 0; ".to_string(), " s(o, o_n)".to_string())
                }
                Ty::String => {
                    cps.push("*mut c_void".into());
                    args.push("&mut o as *mut String as *mut c_void".into());
                    (" -> String".to_string(), "let mut o = String::new(); ".to_string(), " o".to_string())
                }
                _ => return None,
            };
            let head = format!("fn {n}({}){rret}", rps.join(", "));
            let call = |f: &str| format!("unsafe {{ {pre}{f}({});{value} }}", args.join(", "));
            let fty = format!("unsafe extern \"C\" fn({})", cps.join(", "));
            let me = if s.recv == Recv::Mut { "&mut " } else { "&" };
            let mut fwd = vec![format!("{me}self.0")];
            fwd.extend(names.iter().cloned());
            if *provided {
                provided_any = true;
                fields.push(format!("    m_{n}: Option<{fty}>,"));
                let mut d = vec![format!("{me}d")];
                d.extend(names.iter().cloned());
                let _ = write!(imp, "    {head} {{\n        match self.t.m_{n} {{\n            Some(f) => {},\n            None => {{\n                let {}d = Def_{mg}(Volt_{mg} {{ env: self.env, t: VT_{mg} {{ drop: None, ..self.t }} }});\n                {tp}::{n}({})\n            }}\n        }}\n    }}\n", call("f"), if s.recv == Recv::Mut { "mut " } else { "" }, d.join(", "));
            } else {
                fields.push(format!("    m_{n}: {fty},"));
                let _ = writeln!(imp, "    {head} {{\n        {}\n    }}", call(&format!("(self.t.m_{n})")));
                let _ = writeln!(def, "    {head} {{\n        {tp}::{n}({})\n    }}", fwd.join(", "));
            }
        }
        let _ = write!(out, "// {tp} on a Volt value: its methods' table (drop: None when it's lent), and the type implementing the trait by calling it\n#[repr(C)]\n#[derive(Clone, Copy)]\npub struct VT_{mg} {{\n{}\n}}\n\npub struct Volt_{mg} {{\n    env: *mut c_void,\n    t: VT_{mg},\n}}\n\n", fields.join("\n"));
        let _ = write!(out, "// Volt has no Send or Sync: a Volt value another thread uses is the program's to share, as in C\nunsafe impl Send for Volt_{mg} {{}}\nunsafe impl Sync for Volt_{mg} {{}}\n\nimpl Drop for Volt_{mg} {{\n    fn drop(&mut self) {{\n        if let Some(d) = self.t.drop {{\n            unsafe {{ d(self.env) }}\n        }}\n    }}\n}}\n\nimpl {tp} for Volt_{mg} {{\n{imp}}}\n\n");
        if provided_any {
            // ponytail: a default body sees Volt's required methods but Rust's other defaults, even
            // where the Volt type wrote one (Rust can't call a trait's default from an impl)
            let _ = write!(out, "// the trait's own bodies of the methods a Volt type left out, over its required ones\nstruct Def_{mg}(Volt_{mg});\n\nimpl {tp} for Def_{mg} {{\n{def}}}\n\n");
        }
        Some(out)
    }

    fn call(&self, _g: &Gen, module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let args = args.join(", ");
        match (recv, self_ty) {
            // a trait's method: Trait::method(recv, ..), whichever other traits have one so named
            (Some(r), _) if s.call.as_ref().is_some_and(|c| c.starts_with("::")) => format!("{}({r}{}{args})", s.call.as_ref().unwrap(), if args.is_empty() { "" } else { ", " }),
            (Some(r), _) => format!("{r}.{}({args})", s.call.as_ref().unwrap_or(&s.name)),
            (None, Some(ti)) => format!("<{}>::{}({args})", self.path(&ti.def), s.call.as_ref().unwrap_or(&s.name)),
            (None, None) => {
                let mut p = vec![self.lib.clone()];
                p.extend(module.iter().cloned());
                p.push(s.call.clone().unwrap_or_else(|| s.name.clone()));
                format!("::{}({args})", p.join("::"))
            }
        }
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, res: bool) -> String {
        let mut ps = params.to_vec();
        if res {
            ps.extend(["e: *mut *mut u8".to_string(), "e_n: *mut usize".to_string()]);
        }
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "    {l}");
        }
        let _ = writeln!(body, "    let r = {call};");
        for l in post {
            let _ = writeln!(body, "    {l}");
        }
        let store = store.unwrap_or("").replace("$v", "v");
        if res {
            let _ = writeln!(body, "    match r {{\n        Ok(v) => {{ let _ = &v; {store} true }}\n        Err(err) => {{ put_str(err.to_string(), e, e_n); false }}\n    }}");
        } else {
            let _ = writeln!(body, "    let v = r;\n    let _ = &v;\n    {store}");
        }
        format!("#[no_mangle]\npub unsafe extern \"C\" fn {sym}({}){} {{\n{body}}}\n\n", ps.join(", "), if res { " -> bool" } else { "" })
    }

    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String {
        let (rp, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
        let mut out = String::new();
        match ti.kind {
            Kind::Plain => {
                let (mut fields, mut from, mut to) = (String::new(), String::new(), String::new());
                for (f, _, t) in ti.def.fields.clone().unwrap_or_default() {
                    match t {
                        Some(Ty::Prim(x)) => {
                            let _ = writeln!(fields, "    pub {f}: {x},");
                            let _ = write!(from, "{f}: v.{f}, ");
                            let _ = write!(to, "{f}: v.{f}, ");
                        }
                        Some(Ty::Char) => {
                            let _ = writeln!(fields, "    pub {f}: u32,");
                            let _ = write!(from, "{f}: char::from_u32(v.{f}).unwrap_or('\\u{{fffd}}'), ");
                            let _ = write!(to, "{f}: v.{f} as u32, ");
                        }
                        Some(Ty::Named(n)) => {
                            let o = &g.types[&n];
                            let omg = Gen::mangle(&o.def);
                            if o.kind == Kind::Enum {
                                let _ = writeln!(fields, "    pub {f}: i64,");
                                let _ = write!(from, "{f}: from_{omg}(v.{f}), ");
                                let _ = write!(to, "{f}: to_{omg}(&v.{f}), ");
                            } else {
                                let _ = writeln!(fields, "    pub {f}: V_{omg},");
                                let _ = write!(from, "{f}: from_{omg}(&v.{f}), ");
                                let _ = write!(to, "{f}: to_{omg}(&v.{f}), ");
                            }
                        }
                        _ => {}
                    }
                }
                let _ = write!(out, "#[repr(C)]\n#[derive(Clone, Copy)]\npub struct V_{mg} {{\n{fields}}}\nfn from_{mg}(v: &V_{mg}) -> {rp} {{ {rp} {{ {from}}} }}\nfn to_{mg}(v: &{rp}) -> V_{mg} {{ V_{mg} {{ {to}}} }}\n\n");
            }
            Kind::Handle => {
                let drop = g.sym(&[&mg, "drop"]);
                let _ = writeln!(out, "#[no_mangle]\npub unsafe extern \"C\" fn {drop}(h: *mut c_void) {{ drop(Box::from_raw(h as *mut {rp})) }}\n");
                if ti.def.clone {
                    let cl = g.sym(&[&mg, "clone"]);
                    let _ = writeln!(out, "#[no_mangle]\npub unsafe extern \"C\" fn {cl}(h: *mut c_void) -> *mut c_void {{ Box::into_raw(Box::new((*(h as *const {rp})).clone())) as *mut c_void }}\n");
                }
            }
            Kind::Enum => {
                let vs = ti.def.variants.clone().unwrap_or_default();
                let mut from = format!("fn from_{mg}(x: i64) -> {rp} {{\n    match x {{\n");
                let mut to = format!("fn to_{mg}(x: &{rp}) -> i64 {{\n    match x {{\n");
                for (n, x) in &vs {
                    let _ = writeln!(from, "        {x} => {rp}::{n},");
                    let _ = writeln!(to, "        {rp}::{n} => {x},");
                }
                let first = vs.first().map_or(String::new(), |x| x.0.clone());
                let _ = write!(from, "        _ => {rp}::{first},\n    }}\n}}\n");
                // a wildcard for #[non_exhaustive] enums (unreachable, and allowed, for the others)
                let _ = write!(to, "        _ => {},\n    }}\n}}\n\n", vs.first().map_or(0, |x| x.1));
                out.push_str(&from);
                out.push_str(&to);
            }
        }
        out
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_rust_{}_free_{what}", g.alias);
        let mut s = String::from("// the glue between a Volt program and this crate, written by bolt import (use rust)\n#![allow(non_snake_case, non_camel_case_types, unused_parens, unused_unsafe, unused_mut, unused_variables, unreachable_patterns, clippy::all)]\nuse std::ffi::c_void;\n\n");
        s.push_str("// a Volt value the shim owns (a closure Rust keeps): drop frees it\npub struct VoltEnv {\n    env: *mut c_void,\n    drop: Option<unsafe extern \"C\" fn(*mut c_void)>,\n}\nunsafe impl Send for VoltEnv {}\nunsafe impl Sync for VoltEnv {}\nimpl Drop for VoltEnv {\n    fn drop(&mut self) {\n        if let Some(d) = self.drop {\n            unsafe { d(self.env) }\n        }\n    }\n}\n\n");
        s.push_str("#[repr(C)]\npub struct VoltStr {\n    p: *const u8,\n    n: usize,\n}\n#[repr(C)]\npub struct VoltOwnedStr {\n    p: *mut u8,\n    n: usize,\n}\n\n");
        s.push_str("unsafe fn s<'a>(p: *const u8, n: usize) -> &'a str {\n    if n == 0 {\n        return \"\";\n    }\n    let b = std::slice::from_raw_parts(p, n);\n    match std::str::from_utf8(b) {\n        Ok(s) => s,\n        Err(e) => std::str::from_utf8_unchecked(&b[..e.valid_up_to()]),\n    }\n}\n");
        s.push_str("unsafe fn sl<'a, T>(p: *const T, n: usize) -> &'a [T] {\n    if n == 0 { &[] } else { std::slice::from_raw_parts(p, n) }\n}\nunsafe fn slm<'a, T>(p: *mut T, n: usize) -> &'a mut [T] {\n    if n == 0 { &mut [] } else { std::slice::from_raw_parts_mut(p, n) }\n}\n");
        s.push_str("unsafe fn strs<'a>(p: *const VoltStr, n: usize) -> Vec<&'a str> {\n    sl(p, n).iter().map(|x| s(x.p, x.n)).collect()\n}\n");
        s.push_str("unsafe fn put_str(v: String, p: *mut *mut u8, n: *mut usize) {\n    let b = v.into_bytes().into_boxed_slice();\n    *n = b.len();\n    *p = Box::into_raw(b) as *mut u8;\n}\n");
        s.push_str("unsafe fn put_vec<T>(v: Vec<T>, p: *mut *mut T, n: *mut usize) {\n    let b = v.into_boxed_slice();\n    *n = b.len();\n    *p = Box::into_raw(b) as *mut T;\n}\n");
        s.push_str("unsafe fn put_strs(v: Vec<String>, p: *mut *mut VoltOwnedStr, n: *mut usize) {\n    let xs: Vec<VoltOwnedStr> = v.into_iter().map(|x| { let mut q = std::ptr::null_mut(); let mut m = 0; put_str(x, &mut q, &mut m); VoltOwnedStr { p: q, n: m } }).collect();\n    put_vec(xs, p, n);\n}\n\n");
        let fb = free("bytes");
        let _ = writeln!(s, "#[no_mangle]\npub unsafe extern \"C\" fn {fb}(p: *mut u8, n: usize) {{\n    if !p.is_null() {{\n        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, n)));\n    }}\n}}\n");
        for x in &g.vec_elems {
            let _ = writeln!(s, "#[no_mangle]\npub unsafe extern \"C\" fn {}(p: *mut {x}, n: usize) {{\n    if !p.is_null() {{\n        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, n)));\n    }}\n}}\n", free(&format!("{x}s")));
        }
        if g.strs {
            let _ = writeln!(s, "#[no_mangle]\npub unsafe extern \"C\" fn {}(p: *mut VoltOwnedStr, n: usize) {{\n    if !p.is_null() {{\n        for x in Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, n)).iter() {{\n            {fb}(x.p, x.n);\n        }}\n    }}\n}}\n", free("strs"));
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ty(s: &str) -> Option<Ty> {
        parse_ty(&lex(s))
    }

    #[test]
    fn import_types() {
        assert_eq!(ty("&str"), Some(Ty::Str));
        assert_eq!(ty("&'a str"), Some(Ty::Str));
        assert_eq!(ty("String"), Some(Ty::String));
        assert_eq!(ty("&[f64]"), Some(Ty::Slice(Box::new(Ty::Prim("f64")), false)));
        assert_eq!(ty("&mut [u8]"), Some(Ty::Slice(Box::new(Ty::Prim("u8")), true)));
        assert_eq!(ty("Vec<String>"), Some(Ty::Vec(Box::new(Ty::String))));
        assert_eq!(ty("Option<usize>"), Some(Ty::Opt(Box::new(Ty::Prim("usize")))));
        assert_eq!(ty("Result<i64, std::num::ParseIntError>"), Some(Ty::Res(Box::new(Ty::Prim("i64")))));
        assert_eq!(ty("&mut Shape"), Some(Ty::Ref(Box::new(Ty::Named("Shape".into())), true)));
        assert_eq!(ty("shapes::Shape"), Some(Ty::Named("Shape".into())));
        assert_eq!(ty("()"), Some(Ty::Unit));
        assert_eq!(ty("HashMap<String, i32>"), None);
        assert_eq!(ty("impl Fn(i32) -> i32"), None);
        assert_eq!(ty("(i32, i32)"), None);
    }

    #[test]
    fn import_signatures() {
        let s = sig(&lex("pub fn scale(&mut self, k: f64) -> Self"));
        assert!(s.recv == Recv::Mut && s.params.len() == 1 && s.params[0].0 == "k" && s.skip.is_none() && s.ret == Some(Ty::SelfTy));
        let s = sig(&lex("pub fn first<'a>(s: &'a str) -> &'a str"));
        assert!(s.recv == Recv::None && s.skip.is_none() && s.ret == Some(Ty::Str));
        assert_eq!(sig(&lex("pub fn id<T>(x: T) -> T")).skip, Some("it's generic"));
        assert!(sig(&lex("pub fn into_name(self) -> String")).recv == Recv::Value);
        assert!(sig(&lex("pub fn area(&self) -> f64")).recv == Recv::Ref);
        assert_eq!(sig(&lex("pub fn fill(xs: &mut [u8])")).params[0].1, Some(Ty::Slice(Box::new(Ty::Prim("u8")), true)));
    }

    #[test]
    fn import_walks_modules_and_impls() {
        let mut w = Walker::default();
        let src = "pub mod shapes { #[derive(Clone)] pub struct Shape { name: String } impl Shape { pub fn new(n: &str) -> Self { todo!() } fn private(&self) {} } }\n#[derive(Clone, Copy)] pub struct Point { pub x: f64, pub y: f64 }\npub enum Color { Red, Green = 5, Blue }\n#[cfg(test)] mod tests { pub fn t() {} }\npub(crate) fn hidden() {}\npub const LIMIT: i32 = -3;";
        w.walk(&lex(src), &[], Path::new("/none"));
        let m = w.model();
        let names: Vec<String> = m.types.iter().map(|t| format!("{}::{}", t.module.join("::"), t.name)).collect();
        assert_eq!(names, ["shapes::Shape", "::Point", "::Color"]);
        assert_eq!(m.methods["Shape"].len(), 1);
        assert!(m.fns.is_empty(), "the cfg(test) and pub(crate) fns aren't visible");
        assert_eq!(m.types[2].variants, Some(vec![("Red".into(), 0), ("Green".into(), 5), ("Blue".into(), 6)]));
        let lang = Rust { lib: "geom".into() };
        let g = Gen::new(&m, "geom", &lang);
        assert_eq!(g.types["Point"].kind, Kind::Plain);
        assert_eq!(g.types["Shape"].kind, Kind::Handle);
        assert!(g.types["Shape"].def.clone);
        assert_eq!(g.types["Color"].kind, Kind::Enum);
        let (_, volt) = g.write("the crate");
        assert!(volt.contains("namespace shapes {") && volt.contains("attach fn new(static this: geom::shapes::Shape, n: str) -> geom::shapes::Shape") && volt.contains("val LIMIT: i32 = -3;"), "{volt}");
    }
}
