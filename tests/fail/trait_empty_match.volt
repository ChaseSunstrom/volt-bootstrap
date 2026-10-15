// zero arms are only for a trait union with no members: elsewhere the match is still checked
trait shape { fn area(this) -> f64; }
struct circle { r: f64; }
attach shape -> circle { fn area(this) -> f64 { return 3.0; } }
fn f(s: shape) -> void { match (s) {} }
fn main() -> void {}
// error: match doesn't handle circle
