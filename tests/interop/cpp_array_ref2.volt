// cpp_array_ref2.hpp: string views made from a Volt str[2]; an enum array result written through
// into C++'s, a handle-class array result's handles borrowing C++'s elements
use std::io;
use { "cpp_array_ref2.hpp" } as cpp;
fn main() -> void {
    val s: str[2] = { "abc", "de" };
    std::println("views {} {}", cpp::arr2::total_len(s), cpp::arr2::join(s));
    val m = cpp::arr2::modes();
    m[0] = cpp::arr2::Mode::C;
    std::println("modes {} {} {}", cpp::arr2::mode_at(0), cpp::arr2::mode_at(1), @cast<i32>(cpp::arr2::modes()[2]));
    var w = cpp::arr2::widgets();
    w[1].set(20);
    std::println("widgets {} {} {}", w[0].get(), cpp::arr2::widget_at(1), w[1].n());
}
