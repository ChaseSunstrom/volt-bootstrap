// The rest of what a C++ header has: constants are vals, static members static fns, a nested class
// Outer_Inner, operator T() to_T(), operator= assign, a T&& result a value, a member template a
// generic method, and std::function takes a Volt fn value (and comes back as stdcxx::function)
use std::io;
use { "surface.hpp" } as cpp;

fn main() -> void {
    std::println("{} {} {} {} {}", cpp::kit::LIMIT, cpp::kit::RATIO, cpp::kit::ENABLED, cpp::kit::NAME, @cast<i32>(cpp::kit::DEFAULT_LEVEL));
    var c: cpp::kit::Counter = { n: 3 };
    std::println("{} {} {}", cpp::kit::Counter::MAX(), c.to_bool(), c.to_i32());
    c.assign(7);
    val s: cpp::kit::Counter_Step = { by: 5 };
    c.advance(s);
    std::println("{} {} {}", c.n, c.cast_to<f64>() / 8.0, c.cast_to<i64>());
    cpp::kit::Counter::set_created(4);
    std::println("created {}", cpp::kit::Counter::created());
    var r = cpp::kit::Registry::new();
    val e = r.first();
    std::println("{} {} {}", cpp::kit::Registry::label(), e.key(), r.scaled<i32>(21));
    val st = r.steal();
    std::println("stolen {}", st.value());
    val k = 10;
    std::println("{}", cpp::kit::apply(|k| (x: i32) -> i32 { return x * k; }, 4));
    std::println("{}", cpp::kit::twice_apply(|| (x: f64) -> f64 { return x + 0.25; }, 1.0));
    var total = 0;
    cpp::kit::each(4, |total&| (i: i32) -> void { total += i; });
    std::println("{}", cpp::kit::check(|| (t: str) -> bool { return t.len == 3; }));
    val add5 = cpp::kit::adder(5);
    std::println("{} {}", total, add5.call(37));
    std::println("{} {} {}", cpp::kit::TINY < 0.000001, @cast<i32>(cpp::kit::Lamp_Mode::On), @cast<i32>(cpp::kit::Fan_Mode::Slow));
    val sb = cpp::kit::scale_by(3);
    val btn = cpp::kit::Button::new();
    std::println("{} {}", sb.call(5), btn.on().call(8));
    var x = 7;
    std::println("{} {}", cpp::kit::deref_or<i32>(&x, 0), cpp::kit::hold(5).value);
}
