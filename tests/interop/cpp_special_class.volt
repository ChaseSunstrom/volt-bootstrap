// A class template's specializations: box<i32> is the primary's, laid out by Volt (its size is
// C++'s); box<void> (an explicit specialization) and box<i32*> (a partial one) are what clang says
// they are, with their own constructors, fields (read per use) and methods; box<i64> (an explicit
// instantiation, template struct box<long>;) is the primary's
use std::io;
use { "special.hpp" } as cpp;

fn main() -> void {
    val b: cpp::sp::box<i32> = { v: 4, tag: 7 };
    std::println("{} {} {}", b.v, b.get_tag(), @sizeof(cpp::sp::box<i32>) == @cast<usize>(cpp::sp::box_int_size()));
    val s = cpp::sp::box<void>::new(1.5);
    std::println("{} {} {}", s.scaled(4.0), cpp::sp::void_twice(&s), s.scale);
    var x: i32 = 41;
    var p = cpp::sp::box<i32*>::new(&x);
    x += 1;
    std::println("{} {} {}", p.deref(), p.deref(), p.hits);
    std::println("{} {}", cpp::sp::peek(&p), p.hits);
    val l: cpp::sp::box<i64> = { v: 5, tag: 1 };
    std::println("{} {}", l.v, l.get_tag());
    std::println("{}", cpp::sp::quote_mark().code());
}
