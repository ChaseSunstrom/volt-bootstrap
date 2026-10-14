// operators belong to structs and enums: this can't be a number
struct vec2 {
    x: f64;
    y: f64;
}

attach operator *(v: vec2, this: f64) -> vec2 {
    return { x: v.x * this, y: v.y * this };
}

fn main() -> void {}
// error: an operator's this is a struct or an enum (or a reference to one), not f64
