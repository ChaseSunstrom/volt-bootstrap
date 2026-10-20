// a closure literal kept in a std::func is called with the fn type's parameters: types written
// otherwise are refused at the closure
fn make() -> std::func<fn(i32) -> i32> {
    return || (x: i64) -> i64 { return x; };
}

fn main() -> void {
    val f = make();
}
// error: 'x' is a i64 here, but the std::func<fn(i32) -> i32> calls this closure with a i32
