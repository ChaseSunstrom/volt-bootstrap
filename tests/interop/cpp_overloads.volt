// Overloads Volt can't tell apart: the first declared keeps its name, the others are named for their
// parameter types (which_long_long, letter_char, get_const, new_long_long), each calling
// exactly its own C++ overload; a default argument's forms take the name too
use std::io;
use { "overloads.hpp" } as cpp;

// the long long overloads: where long is 64 bits too they collide with the long ones and are named
// for their types; on Windows (a 32-bit long) they keep the name, told apart by an i64
fn which_ll(n: i64) -> i32 {
    comptime if (@cfg("os", "windows")) {
        return cpp::ov::which(n);
    } else {
        return cpp::ov::which_long_long(n);
    }
}

fn f_ll(n: i64) -> i32 {
    comptime if (@cfg("os", "windows")) {
        return cpp::ov::f(n);
    } else {
        return cpp::ov::f_long_long(n);
    }
}

fn f_ll2(n: i64, k: i32) -> i32 {
    comptime if (@cfg("os", "windows")) {
        return cpp::ov::f(n, k);
    } else {
        return cpp::ov::f_long_long(n, k);
    }
}

fn h_ll(x: i64, a: i32, b: i32) -> i32 {
    comptime if (@cfg("os", "windows")) {
        return cpp::ov::h(x, a, b);
    } else {
        return cpp::ov::h_long_long_int_int(x, a, b);
    }
}

fn tally_ll(n: i64) -> cpp::ov::Tally {
    comptime if (@cfg("os", "windows")) {
        return cpp::ov::Tally::new(n);
    } else {
        return cpp::ov::Tally::new_long_long(n);
    }
}

fn add_ll(t: cpp::ov::Tally&, k: i64) -> i32 {
    comptime if (@cfg("os", "windows")) {
        return t.add(k);
    } else {
        return t.add_long_long(k);
    }
}

fn scaled_ll(p: cpp::ov::Point&, k: i64) -> i32 {
    comptime if (@cfg("os", "windows")) {
        return p.scaled(k);
    } else {
        return p.scaled_long_long(k);
    }
}

fn main() -> void {
    std::println("which {} {}", cpp::ov::which(3), which_ll(3));
    std::println("letter {} {} {}", cpp::ov::letter_char(65), cpp::ov::letter(@cast<i8>(65)), cpp::ov::letter(@cast<u8>(65)));
    std::println("f {} {} {} {}", cpp::ov::f(4), cpp::ov::f(4, 2), f_ll(4), f_ll2(4, 2));
    std::println("h {} {} {}", cpp::ov::h(1, 2, 3), cpp::ov::h(1, 2), h_ll(1, 2, 3));
    var a = cpp::ov::Tally::new(5);
    val b = tally_ll(5);
    std::println("new {} {} {} {}", a.get(), a.name(), b.get(), b.name());
    std::println("get {} {}", a.get(), a.get_const());
    std::println("add {} {}", a.add(1), add_ll(&a, 1));
    var p: cpp::ov::Point = { x: 3 };
    std::println("scaled {} {}", p.scaled(2), scaled_ll(&p, 2));
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
    // an && method it inherits (worked out per use) the same: its own object, the handle consumed
    std::println("crate {}", cpp::ov::PinnedCrate::new(5).take());
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
