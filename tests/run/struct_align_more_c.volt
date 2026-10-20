// flags: --backend c
// @align below 32 and generic: @align(16) on a struct of one byte, @align(4) raising a 2-byte
// alignment, a generic struct's @align(N), an optional of one, an empty one, and a struct holding
// one passed by value
use std::io;

@attributes([@align(16)])
struct sixteen { x: u8; }

@attributes([@align(4)])
struct four { a: u8; b: u16; }

<N: usize>
@attributes([@align(N)])
struct sized { v: u32; }

@attributes([@align(32)])
struct empty {}

@attributes([@align(32)])
struct wide { x: u8; y: f64; }

struct holder { tag: u8; w: wide; }

<T: type> fn rem(p: T*, n: usize) -> usize {
    return @cast<usize>(p) % n;
}

fn take(h: holder, s: sixteen) -> usize {
    return rem(&h.w, 32) + rem(&h, 32) + rem(&s, 16) + @cast<usize>(h.tag) + @cast<usize>(s.x);
}

fn main() -> void {
    std::println("sixteen {} {}", @sizeof(sixteen), @alignof(sixteen));
    std::println("four {} {}", @sizeof(four), @alignof(four));
    std::println("sized {} {} {}", @alignof(sized<8>), @alignof(sized<64>), @sizeof(sized<64>));
    std::println("optional {} {}", @sizeof(wide?), @alignof(wide?));
    std::println("empty {} {}", @sizeof(empty), @alignof(empty));
    var a: u8 = 1;
    val s: sixteen = { x: 2 };
    val f: four = { a: 3, b: 4 };
    val z: sized<64> = { v: 5 };
    var o: wide? = { x: 6, y: 7.0 };
    std::println("{} {} {} {}", rem(&s, 16), rem(&f, 4), rem(&z, 64), rem(&o, 32));
    val h: holder = { tag: a, w: { x: 8, y: 9.0 } };
    std::println("by value {}", take(h, s));
}
// expect: sixteen 16 16
// expect: four 4 4
// expect: sized 8 64 64
// expect: optional 64 32
// expect: empty 0 32
// expect: 0 0 0 0
// expect: by value 3
