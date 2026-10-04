// @typeid of a temporary trait value that owns memory: it would leak, so it must be named first
trait thing { fn n(this) -> i32; }
struct boxed { b: std::mem::box<i32>; }
struct plain { v: i32; }
attach thing -> boxed { fn n(this) -> i32 { return *this.b; } }
attach thing -> plain { fn n(this) -> i32 { return this.v; } }
fn make() -> thing {
    val p: plain = { v: 1 };
    return p;
}
fn main() -> void { val id = @typeid(make()); }
// error: @typeid of a temporary trait value that owns memory
