// an operator is a method: its first parameter is this, the left operand
struct vec2 {
    x: i32;
    y: i32;
}

attach operator +(a: vec2, b: vec2) -> vec2 {
    return { x: a.x + b.x, y: a.y + b.y };
}

fn main() -> void {}
// error: operator + takes this as its first parameter
