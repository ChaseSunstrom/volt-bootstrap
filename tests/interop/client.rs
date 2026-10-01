// Rust calls the Volt library through voltc bindings --lang rust: errors come back as Err, owned
// text as String, an export struct is a type that frees itself when dropped
mod mathlib;
use mathlib::*;

fn main() {
    println!("add {}", ml_add(2, 3));
    let mut a = vec2 { x: 1.0, y: 2.0 };
    let b = vec2 { x: 3.0, y: 4.0 };
    println!("dot {}", ml_dot(a, b));
    ml_scale(&mut a, 2.0);
    println!("scale {} {}", a.x, a.y);
    println!("len {}", ml_len("hello"));
    println!("next {}", ml_next(color::GREEN) as i32);
    println!("sqrt {} 1", ml_sqrt(9.0).unwrap());
    let e = ml_sqrt(-1.0).unwrap_err();
    println!("error {}", if e.code == math_error::NEGATIVE { "negative" } else { "?" });
    println!("greet {}", ml_greet("volt"));
    println!("repeat {}", ml_repeat("ab", 2).unwrap());
    println!("repeat {}", ml_repeat("ab", -1).unwrap_err().name().to_lowercase());
    println!("sum {}", ml_sum(&mut [1.0, 2.0, 3.5]));
    let mut ys = [4, 5, 6];
    let none = ml_find(&mut ys, 9).map_or("none".to_string(), |i| i.to_string());
    println!("find {} {}", ml_find(&mut ys, 6).unwrap(), none);
    let mut total = 0;
    print!("each");
    ml_each(&mut ys, &mut |x| {
        total += x;
        print!(" {}", x);
    });
    println!(" = {}", total);
    let c = counter::new("clicks");
    c.add(2);
    println!("counter {} {}", c.name(), c.add(3));
    println!("take {}", c.take(9).unwrap_err().to_string().to_lowercase());
}
