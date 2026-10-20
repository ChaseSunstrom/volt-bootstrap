@attributes([@align(8192)])
struct s { x: u8; }
fn main() -> void { val v: s = { x: 1 }; }
// error: @align(8192)
// error: 4096
