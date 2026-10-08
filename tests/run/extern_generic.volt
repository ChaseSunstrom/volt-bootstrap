use std::io;
// a generic extern "C" fn: each instance is its own C function (a callback per type)
trait shape {
    fn area(this) -> f64;
}
struct sq { side: f64; }
attach shape -> sq {
    fn area(this) -> f64 { return this.side * this.side; }
}
struct ci { r: f64; }
attach shape -> ci {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}
<T: shape>
extern "C" fn area_of(env: void*) -> f64 {
    return @cast<T*>(env)->area();
}
fn call(f: extern "C" fn(void*) -> f64, env: void*) -> f64 {
    return f(env);
}
<T: shape>
fn area(s: T&) -> f64 {
    return call(area_of<T>, @cast<void*>(&*s));
}
fn main() -> void {
    val q: sq = { side: 3.0 };
    var u: shape = { r: 1.0 } as ci;
    std::println("{} {}", area(&q), area(&u));
}
// expect: 9 3
