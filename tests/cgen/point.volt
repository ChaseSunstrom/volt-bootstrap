// the C backend's output for a small program without std, kept as a reviewed snapshot in
// tests/cgen/point/ (tests/selfhost.rs compares it, and builds and runs it)
extern "C" fn printf(fmt: cstr, ...) -> i32;

struct point {
    x: i32;
    y: i32;
}

enum shape {
    DOT,
    CIRCLE: i32,
}

fn add(a: point, b: point) -> point {
    return { x: a.x + b.x, y: a.y + b.y };
}

fn area(s: shape) -> i32 {
    match (s) {
        .DOT => { return 0; },
        .CIRCLE(r) => { return 3 * r * r; },
    }
}

fn main() -> i32 {
    val p = add({ x: 1, y: 2 }, { x: 3, y: 4 });
    var total = 0;
    for (i) in 0..3 {
        total += i;
    }
    if (total > 2) {
        printf("%d %d %d %d\n", p.x, p.y, area(shape::CIRCLE(2)), total);
    } else {
        printf("small\n");
    }
    return 0;
}
