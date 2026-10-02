// @typeid of a temporary trait value that owns memory: it would leak, so it must be named first
trait t_thing { fn n(this) -> i32; }
struct boxed { b: std::mem::box<i32>; }
struct plain { v: i32; }
attach t_thing -> boxed { fn n(this) -> i32 { return *this.b; } }
attach t_thing -> plain { fn n(this) -> i32 { return this.v; } }
fn make() -> t_thing {
    val p: plain = { v: 1 };
    return p;
}
fn main() -> void { val id = @typeid(make()); }
// error: @typeid of a temporary trait value that owns memory
