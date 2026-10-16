// a comptime int constant isn't a bool generic argument (only a bool generic passed on by name is)
<T: type, B: bool>
struct sg {
    v: T;
}
val ONE: i32 = 1;
fn main() -> void { val s: sg<i32, ONE> = { v: 4 }; }
// error: expected a bool known at compile time
