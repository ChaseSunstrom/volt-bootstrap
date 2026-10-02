@attributes([@thread_local])
fn f() -> void {}

fn main() -> void {}
// error: @thread_local goes on a global var (each thread gets its own)
