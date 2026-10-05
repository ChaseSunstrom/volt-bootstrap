// == is eq, which takes the other side by reference
struct vec2 {
    x: i32;
    y: i32;
}

attach operator ==(this: vec2, o: vec2) -> bool {
    return this.x == o.x && this.y == o.y;
}

fn main() -> void {}
// error: operator == takes this and the right operand, both by reference: (this: T&, other: T&)
