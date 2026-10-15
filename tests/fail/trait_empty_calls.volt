// calls through a trait nothing attaches check against the trait's fns: an unknown name and a
// wrong argument count give the errors a trait with members gives
trait plugin { fn run(this, x: i32) -> i32; }
fn a(p: plugin&) -> i32 { return p.nope(); }
fn b(p: plugin&) -> i32 { return p.run(); }
fn c(p: plugin&) -> i32 { return p.run(1, 2); }
fn main() -> void {}
// error: plugin has no method 'nope'
// error: 'run' takes 1 arguments, found 0
// error: 'run' takes 1 arguments, found 2
