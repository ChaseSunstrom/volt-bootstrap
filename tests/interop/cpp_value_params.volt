// cpp_value_params.hpp: an enum value parameter is its integer type in Volt (Mode::B is 1), a char
// one i8 or u8 as the target's char is
use std::io;
use { "cpp_value_params.hpp" } as cpp;
fn main() -> void {
    std::println("tag {} {}", cpp::vp::Tag<1>::id(), cpp::vp::Tag<2>::id());
    std::println("char {} {}", cpp::vp::Ch<65>::get(), cpp::vp::Ch<97>::next());
    val s: cpp::vp::Scale<f64, 2> = { v: 1.5 };
    std::println("scale {}", s.scaled());
    val n = cpp::vp::Named<7>::new();
    std::println("named {}", n.size());
}
