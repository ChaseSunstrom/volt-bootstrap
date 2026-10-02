// a method call that fits no version says why for the versions that take its receiver, not for
// the ones attached to other types
fn main() -> void {
    var v: std::vec<i64> = {};
    val n: i32 = 5;
    v.reserve(n);
}
// error: argument 1 is a i32, but 'reserve' wants a usize
