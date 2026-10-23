// cpp_peruse5.hpp: per-use calls taking T(&)[N] of an enum (C++ writes into the Volt array) and of a
// class held by handle (its objects), nested bool slices, a slice of handles (copied into a
// std::vector), T(&)[M][N] (a Volt T[M][N]), a pointer to a Volt struct's mirrors, and giving back
// a std::vector of a class held by handle (a Volt std::vec of owning handles)
use std::io;
use { "cpp_peruse5.hpp" } as cpp;
struct pt {
    x: i32;
    y: i32;
}
fn main() -> void {
    var ms: cpp::p5::Mode[3] = { cpp::p5::Mode::A, cpp::p5::Mode::B, cpp::p5::Mode::C };
    std::println("modes {} {}", cpp::p5::modes(&ms), @cast<i32>(ms[0]));
    var ws: cpp::p5::Widget[2] = { cpp::p5::Widget::new("x"), cpp::p5::Widget::new("y") };
    std::println("widgets {} {}", cpp::p5::widgets(&ws), ws[1].name());
    val r0: bool[3] = { true, false, true };
    val r1: bool[1] = { true };
    val rows: bool[..][2] = { r0[..], r1[..] };
    std::println("bits {}", cpp::p5::bits(rows[..]));
    std::println("names {}", cpp::p5::names(ws[..]));
    var g: i32[3][2] = { { 1, 2, 3 }, { 4, 5, 6 } };
    std::println("grid {} {}", cpp::p5::grid(&g), g[1][2]);
    val ps: pt[2] = { { x: 1, y: 2 }, { x: 3, y: 4 } };
    val l = cpp::p5::last(&ps[0], 2);
    std::println("last {} {}", l.x, l.y);
    val made = cpp::p5::make_widgets<cpp::p5::Widget>(2);
    std::println("made {} {}{}", made.items().len, made.items()[0].name(), made.items()[1].name());
}
