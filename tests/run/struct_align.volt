// flags: --leak-check
// @align(n) on a struct: its alignment is n and its size a multiple of n, so every value of it
// (a local, a global, an array element, a field, a tuple element, an enum payload, a closure's
// capture, a by-value parameter or result) sits at an address that's a multiple of n
use std::io;

@attributes([@align(32)])
struct wide { x: u8; y: f64; }

struct holder { tag: u8; w: wide; }

enum maybe { NONE, SOME: wide, }

var g: wide = { x: 1, y: 2.0 };

<T: type> fn rem(p: T*) -> usize {
    return @cast<usize>(p) % 32;
}

fn pass(w: wide, pad: u8) -> wide {
    var w2 = w;
    std::println("param {} {}", rem(&w), rem(&w2));
    w2.x += pad;
    return w2;
}

fn main() -> void {
    std::println("wide {} {} {}", @sizeof(wide), @alignof(wide), @typeinfo(wide).align);
    std::println("holder {} {} {}", @sizeof(holder), @alignof(holder), @offsetof(holder, w));
    std::println("tuple {} {}", @sizeof((u8, wide)), @alignof((u8, wide)));
    std::println("maybe {} {}", @sizeof(maybe), @alignof(maybe));
    std::println("array {}", @sizeof(wide[3]));
    var a: u8 = 1;
    var l: wide = { x: 3, y: 4.0 };
    var b: u8 = 2;
    std::println("local {} global {}", rem(&l), rem(&g));
    var arr: wide[3] = { l, l, l };
    std::println("elements {} {} {}", rem(&arr[0]), rem(&arr[1]), rem(&arr[2]));
    var h: holder = { tag: a, w: l };
    std::println("field {} {}", rem(&h), rem(&h.w));
    var t: (u8, wide) = (b, l);
    std::println("tuple element {}", rem(&t.1));
    var m = maybe::SOME(l);
    std::println("payload {}", rem(&m));
    val f = |l| () -> usize { return rem(&l); };
    std::println("capture {}", f());
    val r = pass(l, a);
    std::println("result {} {} {}", rem(&r), r.x, r.y);
}
// expect: wide 32 32 32
// expect: holder 64 32 32
// expect: tuple 64 32
// expect: maybe 64 32
// expect: array 96
// expect: local 0 global 0
// expect: elements 0 0 0
// expect: field 0 0
// expect: tuple element 0
// expect: payload 0
// expect: capture 0
// expect: param 0 0
// expect: result 0 4 4
