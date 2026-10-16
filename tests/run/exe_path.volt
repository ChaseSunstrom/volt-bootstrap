// std::process::exe_path: this program's own file, as an absolute path
use std::io;
use std::fs;
use std::text;
use std::path;

fn main() -> void {
    val p = std::process::exe_path() ?? @panic("exe_path: the system didn't say");
    std::println("{} {}", std::path::is_absolute(p.as_str()), std::fs::exists(p.as_str()));
}
// expect: true true
