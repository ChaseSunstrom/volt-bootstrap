// a std::func lends its fn value only while it lives: a function returns the func itself, not the
// fn value lent from a local one (it would point into the freed closure)
fn make(n: i32) -> std::func<fn(i32) -> i32> {
    return |n| (x) { return x + n; };
}

fn lent() -> fn(i32) -> i32 {
    val f = make(1);
    return f;
}

fn main() -> void {
    val g = lent();
}
// error: can't return 'f' as a fn(i32) -> i32
// error: return the std::func itself
