@attributes([@align(24)])
struct s { x: u8; }
fn main() -> void { val v: s = { x: 1 }; }
// error: @align(24)
// error: power of two
