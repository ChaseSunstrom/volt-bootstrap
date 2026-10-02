// a val can't change, so each thread having its own would mean nothing
@attributes([@thread_local])
val k: i32 = 1;

fn main() -> void {}
// error: @thread_local goes on a global var (each thread gets its own)
