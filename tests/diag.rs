// Diagnostic snapshots: `voltc-bootstrap check` on each tests/diag/NAME.volt must print exactly
// tests/diag/NAME.stderr (colours off). `// flags: ...` on a line passes flags. VOLT_BLESS=1 rewrites
// the snapshots from the current output; review the diff before keeping it. tests/selfhost.rs checks
// that the self-hosted compiler prints the same.

use std::path::Path;
use std::process::Command;

#[test]
fn diagnostics_match_snapshots() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = root.join("tests/diag");
    let bless = std::env::var_os("VOLT_BLESS").is_some();
    let mut files: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect();
    files.sort();
    let mut bad = Vec::new();
    for f in &files {
        let src = std::fs::read_to_string(f).unwrap();
        let flags: Vec<&str> = src.lines().filter_map(|l| l.strip_prefix("// flags: ")).flat_map(|l| l.split_whitespace()).collect();
        let rel = f.strip_prefix(root).unwrap();
        let out = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap"))
            .arg("check")
            .arg(rel)
            .args(&flags)
            .current_dir(root)
            .env_remove("NO_COLOR")
            .output()
            .unwrap();
        let got = String::from_utf8_lossy(&out.stderr).into_owned();
        let snap = f.with_extension("stderr");
        if bless {
            std::fs::write(&snap, &got).unwrap();
            continue;
        }
        let want = std::fs::read_to_string(&snap).unwrap_or_default();
        if out.status.success() || got != want {
            bad.push(format!("{}:\n--- want\n{want}--- got (exit {:?})\n{got}", rel.display(), out.status.code()));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
