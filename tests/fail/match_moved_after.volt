enum pick { LEFT: i32, RIGHT: i32 }
fn eat(s: std::string) -> usize { return s.len(); }
fn main() -> void {
    val s = std::string::from("x");
    val p = pick::LEFT(1);
    match (p) {
        .LEFT(n) => { eat(move s); },
        .RIGHT(n) => {},
    }
    val again = s.len();
}
// error: 's' was moved earlier
