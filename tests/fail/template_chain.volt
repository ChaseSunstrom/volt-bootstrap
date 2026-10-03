// An error inside a template names every instance on the way to it, back to the code that isn't a
// template: here outer<i32> in main, then middle<i32>, then inner<i32>. Sorting a struct with no cmp
// points at the sort call, not only into std.
use std::slice;

struct point {
    x: i32;
}

fn sort_points() -> void {
    var ps: point[2] = { { x: 2 }, { x: 1 } };
    ps[..].sort();
}

<T: type>
fn inner(x: T) -> T {
    return x.missing;
}

<T: type>
fn middle(x: T) -> T {
    return inner(x);
}

<T: type>
fn outer(x: T) -> T {
    return middle(x);
}

fn main() -> void {
    val v = outer(5);
}
// error: i32 has no field 'missing'
// error: inner<i32> is instantiated here
// error: middle<i32> is instantiated here
// error: outer<i32> is instantiated here
// error: can't compare point with <
// error: sort<point, std::mem::default_allocator> is instantiated here
