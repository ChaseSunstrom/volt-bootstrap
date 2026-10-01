use std::io;
// function pointer types whose parameters and results are function pointer types, met first
// through a cast (the C backend defines the inner types before the outer one)

fn main() -> void {
    val a = @cast<extern "C" fn(extern "C" fn(i32) -> i32, i32) -> i32>(address(false));
    std::println("apply {}", a(twice, 20));
    val q = @cast<extern "C" fn(bool) -> extern "C" fn(i64) -> i64>(address(true));
    std::println("pick {}", q(false)(4));
    val held: fn(extern "C" fn(i32) -> i32) -> i32 = || (f: extern "C" fn(i32) -> i32) -> i32 { return f(5); };
    std::println("held {}", held(twice));
}

extern "C" fn twice(x: i32) -> i32 {
    return x * 2;
}

extern "C" fn twice_wide(x: i64) -> i64 {
    return x * 2;
}

extern "C" fn apply(f: extern "C" fn(i32) -> i32, x: i32) -> i32 {
    return f(x) + 1;
}

extern "C" fn pick(neg: bool) -> extern "C" fn(i64) -> i64 {
    return twice_wide;
}

// a C function's address (a typed value first: the address of the function itself)
fn address(which: bool) -> void* {
    if (which) {
        val f: extern "C" fn(bool) -> extern "C" fn(i64) -> i64 = pick;
        return @cast<void*>(f);
    }
    val f: extern "C" fn(extern "C" fn(i32) -> i32, i32) -> i32 = apply;
    return @cast<void*>(f);
}
// expect: apply 41
// expect: pick 8
// expect: held 10
