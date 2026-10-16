// Overloads Volt can't tell apart: the first declared keeps its name, the others are named for their
// parameter types (which_long_long, letter_char, get_const, new_long_long), each calling
// exactly its own C++ overload; a default argument's forms take the name too
use std::io;
use { "overloads.hpp" } as cpp;
fn main() -> void {
    std::println("which {} {}", cpp::ov::which(3), cpp::ov::which_long_long(3));
    std::println("letter {} {} {}", cpp::ov::letter_char(65), cpp::ov::letter(@cast<i8>(65)), cpp::ov::letter(@cast<u8>(65)));
    std::println("f {} {} {} {}", cpp::ov::f(4), cpp::ov::f(4, 2), cpp::ov::f_long_long(4), cpp::ov::f_long_long(4, 2));
    std::println("h {} {} {}", cpp::ov::h(1, 2, 3), cpp::ov::h(1, 2), cpp::ov::h_long_long_int_int(1, 2, 3));
    var a = cpp::ov::Tally::new(5);
    val b = cpp::ov::Tally::new_long_long(5);
    std::println("new {} {} {} {}", a.get(), a.name(), b.get(), b.name());
    std::println("get {} {}", a.get(), a.get_const());
    std::println("add {} {}", a.add(1), a.add_long_long(1));
    var p: cpp::ov::Point = { x: 3 };
    std::println("scaled {} {}", p.scaled(2), p.scaled_long_long(2));
    std::println("call {} {} peek {} {}", p.op_call(1), p.op_call_const(1), p.peek(), p.peek_nonconst());
    // an && method takes the handle by value: a borrowed one's object is copied, not emptied
    val bx = cpp::ov::Box::new(7);
    val c = cpp::ov::Crate::new(8);
    std::println("open {} {} {}", bx.open(), c.as_Box().open_rref(), c.peek());
    std::println("open {}", bx.open_rref());
    std::println("size {} {}", cpp::ov::Box::new(1).size(), cpp::ov::Box::new(1).size_const_rref());
    // ...and on a class that can be neither copied nor moved, its own object (the handle consumed,
    // the object deleted once); a const && method in place, a borrowed handle's too
    std::println("pinned {}", cpp::ov::Pinned::new(3).take());
    std::println("pinned {} {}", cpp::ov::Pinned::new(3).take_const_rref(), cpp::ov::pinned_shelf().take_const_rref());
    std::println("dropped {}", cpp::ov::Pinned::dropped());
    // an abstract class's && method runs in place, through as_Base() too
    std::println("spend {}", cpp::ov::Square::new(4).as_Shape().spend());
    std::println("taken {} {}",cpp::taken::which(3), cpp::taken::which_long_long(3));
    // ...on a class template's instance too (worked out per use): take empties the object, so a
    // borrowed handle's (shelf's reference) object keeps its value
    std::println("holder {} {}", cpp::ov::shelf().take(), cpp::ov::shelf().peek());
    val ho = cpp::ov::Holder<i32>::new(5);
    std::println("holder {} {}", ho.take(), cpp::ov::Holder<i32>::new(6).look());
}
