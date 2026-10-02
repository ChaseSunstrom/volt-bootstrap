trait t_x { fn f(this) -> i32; }

fn unknown() -> void {
    val f = || <T: type>() -> i32 { return 1; };
    f();
}

fn bound() -> void {
    val f = || <T: t_x>(x: T) -> void {};
    f(1);
}

fn value_param() -> void {
    val f = || <N: i32>() -> void {};
}

fn wrong_ret() -> void {
    val f = || <T: type>(x: T) -> void {};
    val g: fn(i32) -> i32 = f;
}

fn lend() -> void {
    val v = 1;
    val set = || <T: type>(p: T&, x: T) -> void { *p = x; };
    set(&v, 2);
}

fn main() -> void {}
// error: can't tell what 'T' is from this call's arguments
// error: T = i32 doesn't attach t_x
// error: a closure's generic parameters are types: <T: type>
// error: for these parameters this closure is a fn(i32) -> void, not a fn(i32) -> i32
// error: 'v' is a val, and a closure changes it (through p): declare it with var
