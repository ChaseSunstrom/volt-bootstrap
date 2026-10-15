// a left operator that doesn't take the right operand's type leaves it unmoved for the right-hand
// one, which borrows it: v is still there after v * s, and dropped once
use std::io;

struct vec2 {
    name: std::string;
    x: f64;
}

struct scale {
    k: f64;
}

attach operator *(this: vec2, k: f64) -> vec2 {
    return { name: copy this.name, x: this.x * k };
}

attach operator *(v: vec2&, this: scale) -> f64 {
    return v.x * this.k;
}

fn main() -> void {
    val v: vec2 = { name: std::string::from("v"), x: 2.0 };
    val s: scale = { k: 3.0 };
    val r = v * s;
    std::println("{} {}", r, v.name);
}
// expect: 6 v
// flags: --leak-check
