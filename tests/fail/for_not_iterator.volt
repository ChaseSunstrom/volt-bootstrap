// a type loops in for only when it attaches next(this: T&) returning an optional or a pointer
struct point {
    x: i32;
}

struct counter {
    n: i32;
}

attach fn next(this: counter&) -> i32 {
    return this.n;
}

fn points() -> void {
    val p: point = { x: 1 };
    for (v) in p {}
}

fn not_optional() -> void {
    var c: counter = { n: 1 };
    for (v) in c {}
}

fn main() -> void {}
// error: can't loop over a point (a type loops when it attaches next(this: point&) -> T? or -> T*)
// error: can't loop over a counter (a type loops when it attaches next(this: counter&) -> T? or -> T*)
