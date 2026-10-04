// nor a closure kept in a local
fn make(k: i32) -> fn(i32) -> i32 {
    val c = |k| (x: i32) -> i32 { return x * k; };
    return c;
}

fn main() -> void {
    val f = make(2);
}
// error: can't return a closure as a fn value
