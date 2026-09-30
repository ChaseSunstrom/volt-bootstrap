// $CC may hold more than the compiler (a wrapper like ccache, or flags): voltc splits it on
// whitespace, for building and for reading C headers (tests/run/c_import.volt does both)
use std::path::Path;
use std::process::Command;

#[test]
fn cc_with_a_wrapper() {
    let o = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap"))
        .args(["run", "tests/run/c_import.volt"])
        .env("CC", "env cc")
        .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")))
        .output()
        .unwrap();
    assert!(o.status.success(), "CC='env cc': {}", String::from_utf8_lossy(&o.stderr));
}
