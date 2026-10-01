use std::io;
// a generic function's instance is a value: f<T> passes as a fn value, or as a C function pointer

extern "C" fn qsort(base: void*, n: usize, size: usize, cmp: extern "C" fn(void*, void*) -> i32) -> void;

// one comparison for any element type, instantiated per type and handed to C
<T: type>
fn ascending(a: void*, b: void*) -> i32 {
    return @cast<T&>(a).cmp(@cast<T&>(b));
}

<T: type>
fn twice(x: T) -> T {
    return x + x;
}

fn apply(f: fn(i32) -> i32, v: i32) -> i32 {
    return f(v);
}

fn main() -> void {
    var xs: i32[] = { 5, 3, 9, 1 };
    qsort(@cast<void*>(&xs), 4, 4, ascending<i32>);
    var ys: f64[] = { 2.5, -1.0, 0.5 };
    qsort(@cast<void*>(&ys), 3, 8, ascending<f64>);
    val f = twice<i32>;
    std::println("{} {} {} {}", xs, ys, f(21), apply(twice<i32>, 4));
}
// expect: { 1, 3, 5, 9 } { -1, 0.5, 2.5 } 42 8
