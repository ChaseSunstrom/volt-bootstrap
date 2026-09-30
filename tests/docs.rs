// The site's documentation: every code block in it compiles (and the ones that show output print
// it), and the std reference is `voltc doc std` (site/src/data/std.json; VOLT_REGEN=1 rewrites it).
use std::path::{Path, PathBuf};
use std::process::Command;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// voltc/src built by the bootstrap compiler, in dir
fn stage1(dir: &Path) -> PathBuf {
    let voltc = dir.join("voltc");
    let mut srcs: Vec<PathBuf> = std::fs::read_dir(Path::new(ROOT).join("voltc/src")).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect();
    srcs.sort();
    let b = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("build").args(&srcs).args(["--cc", "-lLLVM", "--cc", "-lclang", "-o"]).arg(&voltc).output().unwrap();
    assert!(b.status.success(), "building voltc/src failed:\n{}", String::from_utf8_lossy(&b.stderr));
    voltc
}

/// a ```volt block from one of the site's pages
struct Block {
    page: PathBuf,
    line: usize,
    flags: String, // what follows ```volt: `fail`, `ignore`, a title...
    code: String,
    sample: bool, // a whole file under site/src/samples: compiled where it is (its headers are beside it)
}

/// the ```volt blocks of the .md/.mdx pages under dir (or of dir itself, a page)
fn blocks(dir: &Path, out: &mut Vec<Block>) {
    let mut entries: Vec<PathBuf> = if dir.is_dir() { std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect() } else { vec![dir.to_path_buf()] };
    entries.sort();
    for p in entries {
        if p.is_dir() {
            blocks(&p, out);
            continue;
        }
        if !p.extension().is_some_and(|x| x == "md" || x == "mdx") {
            continue;
        }
        let text = std::fs::read_to_string(&p).unwrap();
        let mut lines = text.lines().enumerate();
        while let Some((i, l)) = lines.next() {
            let Some(flags) = l.trim_start().strip_prefix("```volt") else { continue };
            let mut code = String::new();
            for (_, l) in lines.by_ref() {
                if l.trim_start() == "```" {
                    break;
                }
                code.push_str(l);
                code.push('\n');
            }
            out.push(Block { page: p.clone(), line: i + 1, flags: flags.trim().to_string(), code, sample: false });
        }
    }
}

/// the text after each `// key:` line of src
fn directives(src: &str, key: &str) -> Vec<String> {
    let tag = format!("// {key}:");
    src.lines().filter_map(|l| l.trim_start().strip_prefix(&tag).map(|r| r.trim().to_string())).collect()
}

/// Every ```volt block in the site's pages and the README, and every sample under
/// site/src/samples, compiles.
/// A block without `fn main` gets an empty one. `// expect:` lines make it run, printing them, and
/// `// exit: N` run it expecting that exit code; `// flags:` passes flags. Flags after ```volt: `fail` (it must not compile, and each `// error:`
/// text must be in what it prints), `ignore` (skipped) and `bolt` (a build file: it gets the
/// bolt package). Code that imports C++ (`use cpp`) is compiled by the self-hosted voltc, which
/// reads C++ headers
#[test]
fn code_blocks() {
    let root = Path::new(ROOT);
    let mut all = Vec::new();
    blocks(&root.join("site/src/content/docs"), &mut all);
    blocks(&root.join("README.md"), &mut all);
    if let Ok(dir) = std::fs::read_dir(root.join("site/src/samples")) {
        let mut samples: Vec<PathBuf> = dir.map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect();
        samples.sort();
        for p in samples {
            let code = std::fs::read_to_string(&p).unwrap();
            all.push(Block { page: p, line: 1, flags: String::new(), code, sample: true });
        }
    }
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("doc-blocks-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut stage1: Option<PathBuf> = None;
    let mut bad = Vec::new();
    let mut checked = 0;
    for (n, b) in all.iter().enumerate() {
        let flags: Vec<&str> = b.flags.split_whitespace().collect();
        if flags.contains(&"ignore") {
            continue;
        }
        let mut code = b.code.clone();
        if !code.contains("fn main(") {
            code.push_str("\nfn main() -> void {}\n");
        }
        let file = if b.sample {
            b.page.clone()
        } else {
            let f = dir.join(format!("block{n}.volt"));
            std::fs::write(&f, &code).unwrap();
            f
        };
        let expect = directives(&code, "expect");
        let exit: Option<i32> = directives(&code, "exit").first().map(|e| e.parse().unwrap());
        let compiler = if code.contains("use cpp {") { stage1.get_or_insert_with(|| self::stage1(&dir)).clone() } else { PathBuf::from(env!("CARGO_BIN_EXE_voltc-bootstrap")) };
        let mut cmd = Command::new(compiler);
        let run = (!expect.is_empty() || exit.is_some()) && !flags.contains(&"fail");
        cmd.arg(if run { "run" } else { "check" }).arg(&file).arg("--std").arg(root.join("std"));
        for f in directives(&code, "flags") {
            cmd.args(f.split_whitespace());
        }
        // the headers the samples and the interop pages include
        cmd.arg("--cc").arg(format!("-I{}", root.join("site/src/samples").display()));
        if flags.contains(&"bolt") {
            cmd.arg("--pkg").arg(format!("bolt={}", root.join("bolt/api").display()));
        }
        let o = cmd.current_dir(file.parent().unwrap()).output().unwrap();
        let (out, err) = (String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
        let place = format!("{}:{}", b.page.strip_prefix(root).unwrap_or(&b.page).display(), b.line);
        if flags.contains(&"fail") {
            let missing: Vec<String> = directives(&code, "error").into_iter().filter(|e| !err.contains(e.as_str())).collect();
            if o.status.success() || !missing.is_empty() {
                bad.push(format!("{place}: should fail with {missing:?}, printed:\n{err}"));
            }
        } else if o.status.code() != Some(exit.unwrap_or(0)) {
            bad.push(format!("{place}: exited with {:?}\n{err}", o.status.code()));
        } else if !expect.is_empty() && out.lines().map(|l| l.trim_end()).collect::<Vec<_>>() != expect {
            bad.push(format!("{place}: printed\n{out}expected\n{}", expect.join("\n")));
        }
        checked += 1;
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(bad.is_empty(), "{} of {checked} code blocks are wrong:\n\n{}", bad.len(), bad.join("\n\n"));
}

#[test]
fn std_reference() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("docs-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let voltc = stage1(&dir);
    let o = Command::new(&voltc).args(["doc", "std", "--std"]).arg(Path::new(ROOT).join("std")).output().unwrap();
    assert!(o.status.success(), "voltc doc std: {}", String::from_utf8_lossy(&o.stderr));
    let json = String::from_utf8(o.stdout).unwrap();
    // a fn with its comment, a struct with its fields, a method with its receiver, an error set, a
    // file's header comment
    for want in [
        "\"kind\":\"fn\",\"name\":\"println\",\"namespace\":[\"io\"]",
        "\"signature\":\"fn println() -> void\"",
        "\"doc\":\"println(\\\"a {} b {}\\\", x, y) / println(value) / println()\"",
        "\"kind\":\"struct\",\"name\":\"string\"",
        "\"kind\":\"method\",\"name\":\"push\",\"namespace\":[],\"receiver\":\"vec\"",
        "\"kind\":\"error\",\"name\":\"mem_error\"",
        "\"file\":\"json.volt\",\"doc\":\"std::json: JSON values, read from text (parse) and written back (text).",
    ] {
        assert!(json.contains(want), "voltc doc std lacks {want}:\n{json}");
    }
    let path = Path::new(ROOT).join("site/src/data/std.json");
    if std::env::var_os("VOLT_REGEN").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &json).unwrap();
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(have == json, "site/src/data/std.json is stale: VOLT_REGEN=1 cargo test --test docs std_reference");
    let _ = std::fs::remove_dir_all(&dir);
}

/// the README's relative links and images point at files that exist
#[test]
fn readme_links() {
    let root = Path::new(ROOT);
    let text = std::fs::read_to_string(root.join("README.md")).unwrap();
    let mut targets = Vec::new();
    // markdown links and images: ](target)
    for part in text.split("](").skip(1) {
        targets.push(part.split(')').next().unwrap_or("").to_string());
    }
    // html: src="..." and srcset="..."
    for attr in ["src=\"", "srcset=\""] {
        for part in text.split(attr).skip(1) {
            targets.push(part.split('"').next().unwrap_or("").to_string());
        }
    }
    let local: Vec<&String> = targets.iter().filter(|t| !t.contains("://") && !t.starts_with('#') && !t.is_empty()).collect();
    assert!(!local.is_empty(), "the README links to nothing local");
    let broken: Vec<&&String> = local.iter().filter(|t| !root.join(t.split('#').next().unwrap()).exists()).collect();
    assert!(broken.is_empty(), "README links to missing files: {broken:?}");
}
