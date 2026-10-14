// C++ parameters with a Volt form of their own, declared and in calls worked out per use: a
// reference to an array (const or not) takes a Volt array, a function pointer a Volt fn, a
// std::string& a Volt std::string& (C++ changes a copy, which a throw leaves out), and a
// std::function over classes a Volt closure (one held by handle borrowed, one laid out a copy)
use std::io;
use { "params.hpp" } as cpp;
fn inc(x: i32) -> i32 { return x + 1; }
fn mul(a: f64, b: f64) -> f64 { return a * b; }
fn main() -> void {
    var xs: i32[3] = { 1, 2, 3 };
    std::println("sum {}", cpp::pr::sum(xs));
    cpp::pr::fill(&xs, 4);
    std::println("fill {} {} {}", xs[0], xs[1], xs[2]);
    std::println("total {}", cpp::pr::total(xs));
    cpp::pr::twice(&xs);
    std::println("twice {} {}", xs[0], cpp::pr::sum(xs));
    std::println("apply {} {} {}", cpp::pr::apply(inc, 4), cpp::pr::fold(mul, 1.5, 4.0), cpp::pr::apply_t(inc, 9));
    std::println("@cpp {}", @cpp("pr::apply({0}, {1})", inc, 41));
    var t = std::string::from("hi");
    cpp::pr::shout(&t, 2);
    std::println("shout {}", t);
    grown(&t, 2);
    grown(&t, -1);
    @cpp("pr::shout({0}, {1})", &t, 1);
    std::println("@cpp {}", t);
    var sides = 0;
    val shapes = cpp::pr::each_shape(|sides&| (s: cpp::pr::Shape) -> void { sides += s.sides(); });
    std::println("shapes {} {}", shapes, sides);
    val far = cpp::pr::far(|| (k: i32) -> cpp::pr::point { return { x: k * 10, y: k }; });
    std::println("points {} {}", cpp::pr::sum_points(|| (p: cpp::pr::point) -> i32 { return p.x * p.y; }), far);
}
// a throw leaves the Volt string as it was (C++ changed its copy first)
fn grown(t: std::string&, k: i32) -> void {
    val n = cpp::pr::try_grow(t, k) catch |e| {
        std::println("grow {}: {} {}", k, e, t.as_str());
        return;
    };
    std::println("grow {}: {} {}", k, n, t.as_str());
}
