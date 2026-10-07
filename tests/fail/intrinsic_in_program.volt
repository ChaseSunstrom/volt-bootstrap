@attributes([@intrinsic("println")])
fn say(s: str) -> void;
fn main() -> void {}
// error: @intrinsic is for a package's own files (std, a library), not a program's
