// @sizeof and @alignof of an imported C struct are compile-time values: an array length, a comptime
// fn, a val; each matches what C's sizeof and _Alignof say at run time (c_sizeof_comptime.h)
use std::io;
use { "c_sizeof_comptime.h" } as c;

comptime fn point_align() -> usize {
    return @alignof(c::point);
}

val EITHER: usize = @sizeof(c::either);

struct holder {
    p: c::point;
    n: u8;
}

fn main() -> void {
    val buf: u8[@sizeof(c::point)] = {};
    val fl: u8[@sizeof(c::flags)] = {};
    val t: u8[@sizeof(c::tight)] = {};
    std::println("{} {}", buf.len == c::point_size(), point_align() == c::point_align());
    std::println("{} {} {}", fl.len == c::flags_size(), EITHER == c::either_size(), @alignof(c::either) == c::either_align());
    std::println("{} {}", t.len == c::tight_size(), @sizeof(holder) == c::point_size() + c::point_align());
}
// expect: true true
// expect: true true true
// expect: true true
