// Overloads Volt can't tell apart: the first declared keeps its name, the others are named for their
// parameter types (which_long_long, letter_signed_char, get_const, new_long_long), each calling
// exactly its own C++ overload; a default argument's forms take the name too
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    std::println("which {} {}", cpp::ov::which(3), cpp::ov::which_long_long(3));
    std::println("letter {} {} {}", cpp::ov::letter(@cast<i8>(65)), cpp::ov::letter_signed_char(65), cpp::ov::letter(@cast<u8>(65)));
    std::println("f {} {} {} {}", cpp::ov::f(4), cpp::ov::f(4, 2), cpp::ov::f_long_long(4), cpp::ov::f_long_long(4, 2));
    var a = cpp::ov::Tally::new(5);
    val b = cpp::ov::Tally::new_long_long(5);
    std::println("new {} {} {} {}", a.get(), a.name(), b.get(), b.name());
    std::println("get {} {}", a.get(), a.get_const());
    std::println("add {} {}", a.add(1), a.add_long_long(1));
    val p: cpp::ov::Point = { x: 3 };
    std::println("scaled {} {}", p.scaled(2), p.scaled_long_long(2));
    std::println("taken {} {}", cpp::taken::which(3), cpp::taken::which_long_long(3));
}
