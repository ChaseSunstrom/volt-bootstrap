// a top-level comptime item is a call

comptime 1 + 2;

fn main() -> void {}
// error: comptime at the top level runs a call: comptime f(args);
