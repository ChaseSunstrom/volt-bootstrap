// a binary operator takes this and the right operand
struct vec2 {
    x: i32;
    y: i32;
}

attach operator *(this: vec2) -> vec2 {
    return this;
}

fn main() -> void {}
// error: operator * takes two parameters: this and the right operand
