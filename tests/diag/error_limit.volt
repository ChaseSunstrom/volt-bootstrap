// flags: --error-limit 2
// only the first two errors are shown, and the summary says there may be more
fn a() -> i32 { return true; }
fn b() -> i32 { return "b"; }
fn c() -> i32 { return 'c' + false; }

fn main() -> void {}
