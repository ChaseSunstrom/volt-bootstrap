// A class template's specializations: box<i32> is the primary's, laid out by Volt (its size is
// C++'s); box<void> (an explicit specialization) and box<i32*> (a partial one) are what clang says
// they are, with their own constructors, fields and methods
use std::io;
use { "special.hpp" } as cpp;

fn main() -> void {
    val b: cpp::sp::box<i32> = { v: 4, tag: 7 };
    std::println("{} {} {}", b.v, b.get_tag(), @sizeof(cpp::sp::box<i32>) == @cast<usize>(cpp::sp::box_int_size()));
    val s = cpp::sp::box<void>::new(1.5);
    std::println("{} {}", s.scaled(4.0), cpp::sp::void_twice(&s));
    var x: i32 = 41;
    var p = cpp::sp::box<i32*>::new(&x);
    x += 1;
    std::println("{} {}", p.deref(), p.deref());
}
