// sizes, alignments and offsets of Volt's own aggregates: both backends lay them out like C, so
// libraries built by one link into programs built by the other
use std::io;

struct padded { a: u8; b: i64; c: u16; }
enum shape {
    DOT,
    WIDE: u128,
    NAME: (u8, str),
    BOX: padded,
}
error failure { CODE: i32, TEXT: str, }

fn main() -> void {
    std::println("padded {} {} {}", @sizeof(padded), @alignof(padded), @offsetof(padded, c));
    std::println("shape {} {}", @sizeof(shape), @alignof(shape));
    std::println("opt {} {}", @sizeof(padded?), @sizeof(u16?));
    std::println("err {} {}", @sizeof(failure!u8), @sizeof(failure!padded));
    std::println("tuple {} {}", @sizeof((u8, u64, u8)), @sizeof((x: u16, y: u8)));
    std::println("slice {} str {}", @sizeof(i32[..]), @sizeof(str));
    std::println("array {}", @sizeof(padded[3]));
    // a payload's bytes survive copies even where another payload has padding
    var shapes: shape[3] = { shape::NAME((7, "seven")), shape::WIDE(1 << 100), shape::BOX({ a: 1, b: -2, c: 3 }) };
    val copied = shapes;
    for (s&) in copied {
        match (*s) {
            .NAME(p) => { std::println("{} {}", p.0, p.1); },
            .WIDE(w) => { std::println("{}", w >> 99); },
            .BOX(b) => { std::println("{} {} {}", b.a, b.b, b.c); },
            .DOT => {},
        }
    }
}
// expect: padded 24 8 16
// expect: shape 48 16
// expect: opt 32 4
// expect: err 32 48
// expect: tuple 24 4
// expect: slice 16 str 16
// expect: array 72
// expect: 7 seven
// expect: 2
// expect: 1 -2 3
