use { "../run/c_union.h" } as c;
fn main() -> void { val n: c::number = { i: 1, f: 2.0 }; }
// error: a C union's literal sets one member; assign another afterwards
