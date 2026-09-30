// Every source file opens with a comment saying what it is (test programs under tests/*/ are
// exempt: their names and `// expect:` lines say it).

use std::path::Path;

fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            walk(&p, out);
        } else if matches!(p.extension().and_then(|x| x.to_str()), Some("rs" | "volt" | "h")) {
            out.push(p);
        }
    }
}

#[test]
fn every_source_file_has_a_header_comment() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    for d in ["bootstrap", "voltc", "bolt", "std", "runtime", "examples"] {
        walk(&root.join(d), &mut files);
    }
    for e in std::fs::read_dir(root.join("tests")).unwrap() {
        let p = e.unwrap().path();
        if p.extension().is_some_and(|x| x == "rs") {
            files.push(p);
        }
    }
    let bare: Vec<String> = files
        .iter()
        .filter(|p| !p.components().any(|c| c.as_os_str() == "target"))
        .filter(|p| {
            let text = std::fs::read_to_string(p).unwrap();
            let first = text.lines().next().unwrap_or("");
            !(first.starts_with("//") || first.starts_with("/*"))
        })
        .map(|p| p.strip_prefix(root).unwrap().display().to_string())
        .collect();
    assert!(bare.is_empty(), "files without a header comment:\n{}", bare.join("\n"));
}
