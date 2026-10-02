// std::process::exe_path: this program's own file, as an absolute path
use std::io;
use std::fs;
use std::text;

fn main() -> void {
    val p = std::process::exe_path() ?? @panic("exe_path: the system didn't say");
    std::println("{} {}", p.as_str().starts_with("/"), std::fs::exists(p.as_str()));
}
// expect: true true
