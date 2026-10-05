// names in format strings: {name} prints a local, {a::B} a global by path, {p.x} a field path, with
// a spec after a colon; {} keeps taking the given values in order, and the two mix
use std::io;
use std::fmt;

namespace board {
    val NAME: str = "pico";
    val HZ: i32 = 125;
}

struct point {
    x: f64;
    y: f64;
}

struct blinker {
    n: i32;
}

attach fn say(this: blinker&) -> void {
    std::println("{this.n} blinks");
}

fn main() -> void {
    val count = 3;
    std::println("{count} blinks on {board::NAME} at {board::HZ} MHz");
    val p: point = { x: 1.25, y: -2.5 };
    std::println("({p.x:.1}, {p.y:>6.2})");
    std::print("{} and {count} and {}\n", "first", "second");
    val b: blinker = { n: 7 };
    b.say();
    var s: std::string = {};
    std::write(&s, "[{count:03}]");
    val f = std::format("{p.x}|{}|{{count}}", 9);
    std::println("{} {}", s.as_str(), f.as_str());
    val name = std::string::from("owned");
    std::println("{name} {name}");
}
// expect: 3 blinks on pico at 125 MHz
// expect: (1.2,  -2.50)
// expect: first and 3 and second
// expect: 7 blinks
// expect: [003] 1.25|9|{count}
// expect: owned owned
