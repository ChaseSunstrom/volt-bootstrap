// a T(&)[N] of a class Volt holds by handle takes a Volt array of handles (const or not): C++ gets
// copies of their objects, which go back into them once the call returns, not when it threw (a
// try_ form leaves them as they were)
use std::io;
use { "cpp_array_ref.hpp" } as cpp;
fn show(what: str, ws: cpp::ar::Widget[2]&) -> void {
    std::println("{} {} {} {} {}", what, ws[0].label(), ws[0].get(), ws[1].label(), ws[1].get());
}
fn main() -> void {
    var ws: cpp::ar::Widget[2] = { cpp::ar::Widget::new("a", 1), cpp::ar::Widget::new("b", 2) };
    std::println("total {}", cpp::ar::total(&ws));
    cpp::ar::grow(&ws, 10);
    show("grow", &ws);
    std::println("total {}", cpp::ar::total(&ws));
    cpp::ar::try_grow_or_throw(&ws, -5) catch |e| {
        std::println("threw {} {}", e, cpp::last_exception());
    };
    show("kept", &ws);
    cpp::ar::try_grow_or_throw(&ws, 1) catch |e| {
        std::println("threw {}", e);
    };
    show("tried", &ws);
    val ps: cpp::ar::Pin[2] = { cpp::ar::Pin::new(3), cpp::ar::Pin::new(4) };
    std::println("pins {}", cpp::ar::pin_sum(&ps));
}
