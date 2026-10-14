// <= and >= keep their definitions with a right-hand <: 3 <= m is !(m < 3) and m >= 3 is
// !(m < 3), so both need m's < with this first
struct money {
    cents: i64;
}

attach operator <(n: i64, this: money) -> bool {
    return n < this.cents;
}

fn at_least(m: money) -> bool {
    return 3 <= m;
}

fn at_most(m: money) -> bool {
    return m >= 3;
}

fn main() -> void {}
// error: a <= b calls b's operator <, and money has none taking a i32
// error: can't use >= on money; attach operator < to give it one
