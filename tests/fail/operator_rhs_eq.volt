// == takes this first, both by reference: a right-hand == would be the same operator
struct money {
    cents: i64;
}

attach operator ==(o: money&, this: money&) -> bool {
    return o.cents == this.cents;
}

fn main() -> void {}
// error: == takes this first, both T&
