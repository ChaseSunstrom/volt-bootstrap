extern "C" fn rand() -> i32;
@attributes([@align(rand())])
struct s { x: u8; }
fn main() -> void { val v: s = { x: 1 }; }
// error: @align
// error: constant
