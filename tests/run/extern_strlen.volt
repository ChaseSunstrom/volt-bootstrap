// a program's own extern of a C function std also declares (strlen, in std::process and std::fs),
// with another signature: std's are declared under their own C names, so the two never meet
use std::io;

extern "C" fn strlen(s: u8*) -> usize;

fn main() -> void {
    std::println("{} {}", strlen(@cast<u8*>("abc".ptr)), std::process::cwd().len() > 0);
}
// expect: 3 true
