use std::io;

enum color { RED, GREEN, BLUE }
enum code: u8 { OK, WARN = 5, FAIL, }

enum shape {
    CIRCLE: f64,
    RECT: (f64, f64),
    POINT: (x: i32, y: i32),
    EMPTY
}

fn area(s: shape) -> f64 {
    return match (s) {
        .CIRCLE(r) => 3.0 * r * r,
        .RECT(w, h) => w * h,
        .POINT(_, _) => 0.0,
        .EMPTY => -1.0,
    };
}

fn describe(n: i32) -> str {
    return match (n) {
        0 => "zero",
        1..=9 => "small",
        x if x < 0 => "negative",
        default => "big",
    };
}

fn main() -> void {
    val c = color::GREEN;
    std::println(c);
    std::println("{} {}", code::FAIL as i32, c == color::GREEN);
    val shapes: shape[] = { shape::CIRCLE(1.0), shape::RECT(2.0, 3.0), shape::POINT(1, 2), .EMPTY };
    for (s) in shapes {
        std::println("{} -> {}", s, area(s));
    }
    std::println("{} {} {} {}", describe(0), describe(5), describe(-3), describe(50));
    match (c) {
        .RED => std::println("red"),
        default => std::println("not red"),
    }
    val t = (1, true);
    match (t) {
        (1, true) => std::println("one-true"),
        (_, b) => std::println(b),
    }
}
// expect: GREEN
// expect: 6 true
// expect: CIRCLE(1) -> 3
// expect: RECT(2, 3) -> 6
// expect: POINT(1, 2) -> 0
// expect: EMPTY -> -1
// expect: zero small negative big
// expect: not red
// expect: one-true
