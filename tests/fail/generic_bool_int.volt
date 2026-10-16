<T: type, B: bool>
struct sg {
    v: T;
}
fn main() -> void { val s: sg<i32, 1> = { v: 4 }; }
// error: expected a bool known at compile time
