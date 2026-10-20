@attributes([@align(0)])
struct s { x: u8; }
fn main() -> void { val v: s = { x: 1 }; }
// error: @align(0)
// error: power of two
