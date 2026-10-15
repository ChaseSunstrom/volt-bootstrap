// an @optional static fn through a union where a member lacks it: the error names that member
trait shape {
    fn area(this) -> f64;
    @attributes([@optional])
    fn sides(static this) -> i32;
}
struct circle { r: f64; }
struct square { side: f64; }
attach shape -> circle { fn area(this) -> f64 { return 3.0; } }
attach shape -> square {
    fn area(this) -> f64 { return 1.0; }
    fn sides(static this) -> i32 { return 4; }
}
fn main() -> void {
    val q: square = { side: 1.0 };
    val s: shape = q;
    val n = s.sides();
}
// error: 'sides' isn't attached to circle
