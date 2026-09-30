// half and quad precision floats: arithmetic, conversions, comparisons, and through memory
use std::io;

struct pair { h: f16; q: f128; }

fn scale(p: pair, k: f16) -> pair {
    return { h: p.h * k, q: p.q * @cast<f128>(k) };
}

fn main() -> void {
    var h: f16 = 1.5;
    h = h + 0.25;
    val q: f128 = 1.0 / 3.0;
    std::println("{} {}", h, @cast<f64>(q * 3.0));
    val p = scale({ h: 2.0, q: 10.5 }, 4.0);
    std::println("{} {}", p.h, p.q);
    std::println("{} {}", h < 2.0, q > 0.3);
    std::println("{} {}", @cast<i32>(p.h), @cast<i64>(p.q));
}
// expect: 1.75 1
// expect: 8 42
// expect: true true
// expect: 8 42
