// a str is a read-only view (often of a string literal): (c&) would let the loop write into it
fn main() -> void {
    val s: str = "abc";
    for (c&) in s {
        *c = 'x';
    }
}
// error: a str is read-only, so (x&) can't point into it; loop over it by value instead
