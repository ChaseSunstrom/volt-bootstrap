// A function that can throw has a try_ form whatever it returns (a class held by handle, a
// reference, an optional, a vector), returning a cpp_error naming the exception. And an exception
// thrown by C++ that Volt called inside a callback reaches the C++ that called the callback, with
// its own type
use std::io;
use { "errors.hpp" } as cpp;

fn made(v: i32) -> void {
    val b = cpp::ex::try_make(v) catch |e| {
        std::println("make {}: {} {}", v, e, cpp::last_exception());
        return;
    };
    std::println("make {}: {}", v, (b ?? return).v());
}

fn at(s: cpp::ex::Store&, i: i32) -> void {
    val b = s.try_at(i) catch |e| {
        std::println("at {}: {} {}", i, e, cpp::last_exception());
        return;
    };
    std::println("at {}: {}", i, b.v());
}

fn parsed(t: str) -> void {
    val n = cpp::ex::try_parse(t) catch |e| {
        std::println("parse '{}': {} {}", t, e, cpp::last_exception());
        return;
    };
    std::println("parse '{}': {}", t, n ?? -1);
}

fn ranged(n: i32) -> void {
    val xs = cpp::ex::try_range(n) catch |e| {
        std::println("range {}: {} {}", n, e, cpp::last_exception());
        return;
    };
    std::println("range {}: {}", n, xs.len);
}

struct doubler {
    n: i32;
}

attach cpp::ex::Visitor -> doubler {
    fn visit(this, self: cpp::ex::Visitor&, x: i32) -> i32 { return cpp::ex::check(x) * this.n; }
}

fn slot(s: cpp::ex::Store&, i: i32) -> void {
    val r = s.try_slot(i) catch |e| {
        std::println("slot {}: {}", i, e);
        return;
    };
    std::println("slot {}: {}", i, *r);
}

fn limited(x: i32) -> void {
    val n = cpp::ex::Store::try_limit(x) catch |e| {
        std::println("limit {}: {}", x, e);
        return;
    };
    std::println("limit {}: {}", x, n);
}

fn boxed(x: i32) -> void {
    val b = cpp::ex::Box::try_new(x) catch |e| {
        std::println("new {}: {}", x, e);
        return;
    };
    std::println("new {}: {}", x, b.v());
}

fn paired(x: i32) -> void {
    val p = cpp::ex::Pair<i32, f64>::try_new(x, 0.5) catch |e| {
        std::println("pair {}: {}", x, e);
        return;
    };
    std::println("pair {}: {} {}", x, p.a, p.b);
}

fn halved(s: cpp::ex::Store&, x: i32) -> void {
    val h = s.try_as<f64>(x) catch |e| {
        std::println("as {}: {}", x, e);
        return;
    };
    std::println("as {}: {}", x, h);
}

fn main() -> void {
    made(2);
    made(-2);
    var s: cpp::ex::Store = {};
    at(&s, 0);
    at(&s, 3);
    parsed("42");
    parsed("x");
    parsed("");
    ranged(3);
    ranged(-1);
    std::println("{}", cpp::ex::run(|| (x: i32) -> i32 { return cpp::ex::check(x) * 10; }, 2));
    std::println("{}", cpp::ex::run(|| (x: i32) -> i32 { return cpp::ex::check(x) * 10; }, 5));
    // a try_ form inside the callback catches it there instead
    std::println("{}", cpp::ex::run(|| (x: i32) -> i32 { return cpp::ex::try_check(x) catch |e| { return -1; }; }, 5));
    // what an override of a virtual method throws reaches the C++ calling it
    val d: doubler = { n: 3 };
    var v = cpp::ex::Visitor::derive(move d);
    std::println("{}", cpp::ex::walk(&v, 2));
    std::println("{}", cpp::ex::walk(&v, 8));
    // static methods, constructors (of a class template's instance too), method templates, a
    // number by reference
    limited(4);
    limited(12);
    boxed(-5);
    paired(-1);
    paired(1);
    halved(&s, 5);
    halved(&s, -5);
    slot(&s, 0);
    slot(&s, 1);
}
