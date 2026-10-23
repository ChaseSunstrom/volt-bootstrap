// cpp_fnptr_types.hpp: a function pointer parameter whose signature has a class Volt lays out (by
// reference), an enum or a reference to a number takes a named Volt fn of that signature
use std::io;
use { "cpp_fnptr_types.hpp" } as cpp;
fn area(s: cpp::fp::Shape&) -> f64 { return s.w * s.h; }
fn say(m: cpp::fp::Mode) -> void { std::println("mode {}", @cast<i32>(m)); }
fn nine(s: cpp::fp::Small) -> i32 { return @cast<i32>(s) * 10; }
fn after(m: cpp::fp::Mode) -> cpp::fp::Mode {
    if (m == cpp::fp::Mode::OFF) {
        return cpp::fp::Mode::ON;
    }
    return cpp::fp::Mode::AUTO;
}
fn widen(s: cpp::fp::Shape&) -> void { s.w = s.w * 2.0; }
fn inc(x: i32&) -> void { *x += 1; }
fn second(a: cpp::fp::Shape&, b: cpp::fp::Shape&) -> cpp::fp::Shape& { return b; }
fn main() -> void {
    var v: std::vec<cpp::fp::Shape> = {};
    v.push({ w: 2.0, h: 3.0 });
    v.push({ w: 1.0, h: 4.0 });
    std::println("each {}", cpp::fp::each(v.items(), area));
    cpp::fp::on(cpp::fp::Mode::AUTO, say);
    std::println("small {}", cpp::fp::small(cpp::fp::Small::S9, nine));
    std::println("next {}", @cast<i32>(cpp::fp::next(cpp::fp::Mode::OFF, after)));
    var s: cpp::fp::Shape = { w: 1.5, h: 1.0 };
    val t: cpp::fp::Shape = { w: 1.0, h: 1.0 };
    cpp::fp::grow(&s, widen);
    std::println("grow {}", s.w);
    std::println("bump {}", cpp::fp::bump(4, inc));
    std::println("bigger {}", cpp::fp::bigger(&s, &t, second));
    std::println("scale {}", cpp::fp::scale(2, area, &t));
    std::println("twice {}", cpp::fp::twice<cpp::fp::Shape>(&s, area));
    std::println("small_t {}", cpp::fp::small_t(3, nine));
    std::println("with_ref {}", cpp::fp::with_ref(inc));
}
