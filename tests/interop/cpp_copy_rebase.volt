// cpp_copy_rebase.hpp: a string_view, pointer or reference result into a parameter's copy points at
// the same place in the str or slice it was made from
use std::io;
use { "cpp_copy_rebase.hpp" } as cpp;

fn at(p: void*, base: void*) -> usize {
    return @cast<usize>(p) - @cast<usize>(base);
}

fn main() -> void {
    val s = "  hello  ";
    val t = cpp::cr::trim(s);
    std::println("trim [{}] at {}", t, at(@cast<void*>(t.ptr), @cast<void*>(s.ptr)));
    val xs: i32[4] = { 3, 9, 4, 1 };
    val b = cpp::cr::biggest(xs[0..4]);
    std::println("biggest {} at {}", *b, at(@cast<void*>(b), @cast<void*>(&xs[0])) / 4);
    val ps: cpp::cr::pt[3] = { { x: 5, y: 1 }, { x: 2, y: 7 }, { x: 4, y: 0 } };
    val l = cpp::cr::leftmost(ps[0..3]);
    std::println("leftmost {} {} at {}", l.x, l.y, at(@cast<void*>(&*l), @cast<void*>(&ps[0])) / 8);
}
