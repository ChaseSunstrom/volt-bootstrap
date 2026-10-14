// a > b is b < a: 3 > m calls m's operator < (this first) with 3, and a right-hand < doesn't serve it
struct money {
    cents: i64;
}

attach operator <(n: i32, this: money) -> bool {
    return @cast<i64>(n) < this.cents;
}

fn more(m: money) -> bool {
    return 3 > m;
}

fn main() -> void {}
// error: a > b calls b's operator <, and money has none taking a i32
