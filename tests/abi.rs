// The C calling conventions the LLVM backend lowers to, checked against clang: for each host
// ($VOLT_TRIPLE), every export fn in tests/abi/sigs.volt has to lower to the signature clang gives
// sigs.c's matching C (types, sret, byval, signext/zeroext, alignstack), the way clang's own ABI
// tests check its IR; and on aarch64, C and Volt calling each other run under qemu-aarch64
mod common;

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

const HOSTS: [&str; 4] = ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "arm64-apple-macosx14.0.0", "x86_64-pc-windows-msvc"];

fn run(cmd: &mut Command, what: &str) -> String {
    let o = cmd.output().unwrap_or_else(|e| panic!("{what}: {e}"));
    assert!(o.status.success(), "{what} failed:\n{}", String::from_utf8_lossy(&o.stderr));
    String::from_utf8(o.stdout).unwrap()
}

fn have(tool: &str) -> bool {
    Command::new(tool).arg("--version").output().is_ok_and(|o| o.status.success())
}

/// the text from s[open] (an opening bracket) up to its match
fn group(s: &str, open: usize) -> &str {
    let mut depth = 0;
    for (i, c) in s[open..].char_indices() {
        match c {
            '(' | '{' | '[' | '<' => depth += 1,
            ')' | '}' | ']' | '>' => {
                depth -= 1;
                if depth == 0 {
                    return &s[open..open + i + 1];
                }
            }
            _ => {}
        }
    }
    panic!("unbalanced: {s}")
}

/// s with each named type (%struct.x, %"x") written out as its body, so clang's names and voltc's
/// literal structs compare
fn resolve(s: &str, types: &HashMap<String, String>) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('%') {
        out.push_str(&rest[..i]);
        let name_len = rest[i + 1..].find(|c: char| !(c.is_alphanumeric() || "._\"-".contains(c))).unwrap_or(rest.len() - i - 1);
        let name = &rest[i + 1..i + 1 + name_len];
        match types.get(name) {
            Some(body) => out.push_str(&resolve(body, types)),
            None => out.push_str(&rest[i..i + 1 + name_len]),
        }
        rest = &rest[i + 1 + name_len..];
    }
    out.push_str(rest);
    out
}

/// one param's or the result's lowering, without what the ABI doesn't decide: value names, and the
/// attributes clang adds for its optimizer (noundef, align, dead_on_return, ...)
fn normalize(part: &str, types: &HashMap<String, String>) -> String {
    let s = resolve(part, types);
    let mut words = Vec::new();
    let mut rest = s.trim();
    while !rest.is_empty() {
        let end = rest.find(' ').unwrap_or(rest.len());
        let open = rest[..end].find(['(', '{', '[', '<']);
        let (word, next) = match open {
            // a word with a bracketed group (sret({ i64 }), [2 x i64], alignstack(8)) runs to its end
            Some(o) => {
                let g = group(rest, o);
                (&rest[..o + g.len()], o + g.len())
            }
            None => (&rest[..end], end),
        };
        rest = rest[next..].trim_start();
        let bare = word.split('(').next().unwrap();
        if word.starts_with('%') || word.starts_with('#') || matches!(bare, "noundef" | "dso_local" | "dead_on_unwind" | "writable" | "dead_on_return" | "nonnull" | "noalias" | "nocapture" | "readonly" | "writeonly" | "local_unnamed_addr" | "captures" | "dereferenceable" | "range" | "nofpclass") {
            continue;
        }
        if bare == "align" {
            let end = rest.find(' ').unwrap_or(rest.len());
            rest = rest[end..].trim_start(); // its number
            continue;
        }
        // sret and byval's type is the struct's own, the same layout on both sides
        words.push(if bare == "sret" || bare == "byval" { bare.to_string() } else { word.to_string() });
    }
    words.join(" ")
}

/// each defined fn's lowered signature in an IR module: name -> [result, params...]
fn signatures(ir: &str) -> HashMap<String, Vec<String>> {
    let mut types = HashMap::new();
    for line in ir.lines() {
        if let Some((name, body)) = line.strip_prefix('%').and_then(|l| l.split_once(" = type ")) {
            types.insert(name.to_string(), body.to_string());
        }
    }
    let mut out = HashMap::new();
    for line in ir.lines().filter(|l| l.starts_with("define ")) {
        let at = line.find(" @").unwrap();
        let open = at + line[at..].find('(').unwrap();
        let name = &line[at + 2..open];
        let mut parts = vec![normalize(&line["define ".len()..at], &types)];
        let params = group(line, open);
        let inner = &params[1..params.len() - 1];
        let (mut depth, mut from) = (0, 0);
        for (i, c) in inner.char_indices() {
            match c {
                '(' | '{' | '[' | '<' => depth += 1,
                ')' | '}' | ']' | '>' => depth -= 1,
                ',' if depth == 0 => {
                    parts.push(normalize(&inner[from..i], &types));
                    from = i + 1;
                }
                _ => {}
            }
        }
        if !inner.trim().is_empty() {
            parts.push(normalize(&inner[from..], &types));
        }
        out.insert(name.to_string(), parts);
    }
    out
}

#[test]
fn signatures_match_clang() {
    if !have("clang") {
        eprintln!("abi: skipped (no clang)");
        return;
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let voltc = common::voltc();
    let mut bad = Vec::new();
    for host in HOSTS {
        let c_ir = run(Command::new("clang").arg(format!("--target={host}")).args(["-ffreestanding", "-O0", "-S", "-emit-llvm", "-o", "-"]).arg(root.join("tests/abi/sigs.c")), "clang");
        let volt_ir = run(Command::new(&voltc).arg("emit-llvm").arg(root.join("tests/abi/sigs.volt")).arg("--std").arg(root.join("std")).env("VOLT_TRIPLE", host), "voltc emit-llvm");
        let want = signatures(&c_ir);
        let got = signatures(&volt_ir);
        assert!(want.len() >= 20, "{host}: clang defined only {want:?}");
        for (name, w) in &want {
            match got.get(name) {
                Some(g) if g == w => {}
                g => bad.push(format!("{host} {name}:\n  clang: {w:?}\n  voltc: {g:?}")),
            }
        }
    }
    assert!(bad.is_empty(), "voltc lowers these unlike clang:\n{}", bad.join("\n"));
}

#[test]
fn aarch64_round_trip() {
    if !["clang", "ld.lld", "qemu-aarch64"].iter().all(|t| have(t)) {
        eprintln!("abi: skipped the aarch64 round trip (needs clang, ld.lld and qemu-aarch64)");
        return;
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("abi-aarch64");
    std::fs::create_dir_all(&dir).unwrap();
    let ll = run(Command::new(common::voltc()).arg("emit-llvm").arg(root.join("tests/abi/round.volt")).arg("--std").arg(root.join("std")).arg("--release").env("VOLT_TRIPLE", "aarch64-unknown-linux-gnu"), "voltc emit-llvm");
    std::fs::write(dir.join("round.ll"), ll).unwrap();
    let clang = |src: &Path, obj: &str| run(Command::new("clang").args(["--target=aarch64-linux-gnu", "-O1", "-ffreestanding", "-fno-stack-protector", "-fno-pic", "-ffunction-sections", "-c"]).arg(src).arg("-o").arg(dir.join(obj)), "clang");
    clang(&dir.join("round.ll"), "round.o");
    clang(&root.join("tests/abi/harness.c"), "harness.o");
    // only what _start reaches is kept: the program's main and its runtime calls drop out
    run(Command::new("ld.lld").args(["-static", "-e", "_start", "--gc-sections", "-o"]).arg(dir.join("round")).arg(dir.join("harness.o")).arg(dir.join("round.o")), "ld.lld");
    let o = Command::new("qemu-aarch64").arg(dir.join("round")).output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && out == "ok\n", "C and Volt disagree on aarch64 (exit {:?}):\n{out}", o.status.code());
}
