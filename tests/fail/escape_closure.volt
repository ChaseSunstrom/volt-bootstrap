// a fn value borrows its closure: a closure written in the return is gone once the function returns
fn make(k: i32) -> fn(i32) -> i32 {
    return |k| (x: i32) -> i32 { return x * k; };
}

fn main() -> void {
    val f = make(2);
}
// error: can't return a closure as a fn value
