// calls worked out per use have try_ forms too: ns::try_f(...) returns the exception as a cpp_error,
// as a declared function's try_ form does, a std::string& left as it was; a try_ name the header
// declares itself is that function
use std::io;
use { "params.hpp" } as cpp;
fn checked(a: i32, b: i32) -> void {
    val n = cpp::pr::pu::try_checked(a, b) catch |e| {
        std::println("checked {} {}: {} {}", a, b, e, cpp::last_exception());
        return;
    };
    std::println("checked {} {}: {}", a, b, n);
}
fn stretched(t: std::string&, k: i32) -> void {
    val n = cpp::pr::pu::try_stretch(t, k) catch |e| {
        std::println("stretch {}: {} {}", k, e, t.as_str());
        return;
    };
    std::println("stretch {}: {} {}", k, n, t.as_str());
}
fn main() -> void {
    checked(2, 3);
    checked(2, -5);
    var t = std::string::from("hi");
    stretched(&t, 2);
    stretched(&t, -1);
    cpp::pr::pu::try_boom(1) catch |e| {
        std::println("boom 1: {}", e);
    };
    cpp::pr::pu::try_boom(1, 2) catch |e| {
        std::println("boom 2: {}", e);
    };
    std::println("twin {} {}", cpp::pr::pu::twin(2, 3), cpp::pr::pu::try_twin(5));
    // a class held by handle, its members worked out per use
    kept(3);
    kept(-2);
    val held = cpp::pr::pu::Keep<i32>::try_new(4) catch |e| {
        std::println("keep 4: {}", e);
        return;
    };
    val got = held.try_take(-1) catch |e| {
        std::println("take -1: {} {}", e, held.take(1));
        return;
    };
    std::println("take -1: {}", got);
}
fn kept(x: i32) -> void {
    val k = cpp::pr::pu::Keep<i32>::try_new(x) catch |e| {
        std::println("keep {}: {}", x, e);
        return;
    };
    std::println("keep {}: {}", x, k.take(0));
}
