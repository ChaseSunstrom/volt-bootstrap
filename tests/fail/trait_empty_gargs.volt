// generic arguments on a call through a trait nothing attaches: refused as for a trait with members
trait plugin { fn run(this, x: i32) -> i32; }
fn a(p: plugin&) -> i32 { return p.run<i32>(1); }
fn main() -> void {}
// error: too many generic arguments for 'run'
