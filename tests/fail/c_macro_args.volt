// a C macro or varargs function made per use: a call C rejects, an argument C has no type for, an
// argument with no type of its own, generic arguments; a val C's macro would change; a result Volt
// has no type for; an int's result is an i32; a va_list function with nothing before the va_list
use { "../run/c_macros.h" } as m;

struct mine {
    a: i32;
}

fn rejected() -> i32 {
    return m::PT_SUM(5);
}

fn text(s: str) -> i32 {
    return m::MAX(s, 1);
}

fn untyped() -> i32 {
    return m::MAX(null, 1);
}

fn generic() -> i32 {
    return m::SQUARE<i32>(2);
}

fn volt_struct(v: mine) -> i32 {
    return m::MAX(v, 1);
}

fn val_place() -> i32 {
    val k: i32 = 5;
    return m::INC(k);
}

fn anon_result() -> i32 {
    val r = m::ANON();
    return 0;
}

fn int_result() -> bool {
    val a: i32 = 2;
    return m::SQUARE(a);
}

fn va_list_only() -> i32 {
    return m::vonly(1);
}

fn main() -> void {}
// error: C can't make this call, PT_SUM(int)
// error: C has no type for str, an argument of MAX
// error: give this one a type
// error: a C macro or function takes no generic arguments
// error: C has no type for mine, an argument of MAX
// error: C can't make this call, INC(int)
// error: cannot assign to variable 'volt_a0' with const-qualified type
// error: ANON() gives a struct
// error: expected bool, found i32
// error: unknown name 'vonly'
