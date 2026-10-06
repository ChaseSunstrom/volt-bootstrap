// match arms with alternatives, p1 | p2 => body: literals, ranges, enum variants (with the same
// binding in each), with a guard, and in comptime match; a match is exhaustive when they cover it
use std::io;

enum shape {
    CIRCLE: f64,
    SQUARE: f64,
    LINE,
    POINT,
}

fn kind(c: u8) -> str {
    match (c) {
        '(' | ')' | '[' | ']' => { return "bracket"; },
        '0'..='9' | '_' => { return "digit or _"; },
        ' ' | '\t' | '\n' => { return "space"; },
        default => { return "other"; },
    }
}

// every variant is covered, by alternatives: no default needed
fn size(s: shape) -> f64 {
    match (s) {
        .CIRCLE(r) | .SQUARE(r) => { return r; },
        .LINE | .POINT => { return 0.0; },
    }
}

fn small(n: i32) -> str {
    match (n) {
        1 | 2 | 3 if n != 2 => { return "odd small"; },
        1 | 2 | 3 => { return "two"; },
        default => { return "big"; },
    }
}

// what a reference, pointer or slice points at, by name (t is bound by each alternative)
<T: type>
comptime fn pointee() -> str {
    match (@typeinfo(T).kind) {
        .REFERENCE(t) | .POINTER(t) | .SLICE(t) => { return @typeinfo(t).short_name; },
        default => { return "none"; },
    }
}

fn main() -> void {
    std::println("{} {} {} {}", kind('('), kind('7'), kind('\t'), kind('x'));
    std::println("{} {} {}", size(shape::SQUARE(2.5)), size(shape::CIRCLE(1.5)), size(shape::LINE));
    std::println("{} {} {}", small(1), small(2), small(9));
    std::println("{} {} {}", pointee<i32&>(), pointee<f64[..]>(), pointee<bool>());
}
// expect: bracket digit or _ space other
// expect: 2.5 1.5 0
// expect: odd small two big
// expect: i32 f64 none
