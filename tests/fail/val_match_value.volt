// a reference from a match is read-only when any arm's is
fn main() -> void {
    val x = 0;
    var y = 0;
    val n = 1;
    val q = match (n) {
        1 => &x,
        default => &y,
    };
    *q = 1;
}
// error: can't assign through this; it reaches a val (or a parameter without var)
