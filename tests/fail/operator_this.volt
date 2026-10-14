// an operator is a method: this is its first parameter (the left operand) or its second (the right)
struct vec2 {
    x: i32;
    y: i32;
}

attach operator +(a: vec2, b: vec2) -> vec2 {
    return { x: a.x + b.x, y: a.y + b.y };
}

fn main() -> void {}
// error: an operator takes this as its first or second parameter
