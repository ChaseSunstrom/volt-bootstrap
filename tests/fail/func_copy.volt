// a std::func owns its closure: it moves, but has no copy (both copies would delete it)
fn make(n: i32) -> std::func<fn(i32) -> i32> {
    return |n| (x) { return x + n; };
}

fn main() -> void {
    val a = make(1);
    val b = copy a;
}
// error: can't copy std::func
