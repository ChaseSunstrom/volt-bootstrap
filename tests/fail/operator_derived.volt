// <= comes from <, so it can't be attached itself
struct money {
    cents: i64;
}

attach operator <=(this: money, o: money) -> bool {
    return this.cents <= o.cents;
}

fn main() -> void {}
// error: <= can't be attached: it comes from operator <
