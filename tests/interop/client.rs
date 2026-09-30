// Rust calls the Volt library through voltc bindings --lang rust
mod mathlib;
use mathlib::*;

fn main() {
    unsafe {
        println!("add {}", ml_add(2, 3));
        let mut a = vec2 { x: 1.0, y: 2.0 };
        let b = vec2 { x: 3.0, y: 4.0 };
        println!("dot {}", ml_dot(a, b));
        ml_scale(&mut a, 2.0);
        println!("scale {} {}", a.x, a.y);
        println!("len {}", ml_len(VoltStr::from("hello")));
        println!("next {}", ml_next(color::GREEN) as i32);
        let r = ml_sqrt(9.0);
        println!("sqrt {} {}", r.value, (r.error == 0) as i32);
        let r = ml_sqrt(-1.0);
        println!("error {}", if r.error == math_error::NEGATIVE { "negative" } else { "?" });
    }
}
