@attributes([@align(4)])
struct s { x: u64; }
fn main() -> void { val v: s = { x: 1 }; }
// error: @align(4)
// error: below
// error: 8
