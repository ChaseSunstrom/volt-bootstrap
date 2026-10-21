// a C member declared with __attribute__((vector_size(N))), and one of a typedef'd vector, are
// Volt vectors with C's layout: sizes and offsets agree, and lanes written in Volt reach C
use std::io;
use { "c_vector_size.h" } as c;

fn main() -> void {
    var s: c::vs = {};
    s.tag = 1;
    for (i) in 0..8 {
        s.v[i] = @cast<i32>(i);
    }
    s.f[2] = 2.5;
    std::println("{} {} {}", @sizeof(c::vs) == c::vs_size(), @offsetof(c::vs, v) == c::vs_off_v(), @offsetof(c::vs, f) == c::vs_off_f());
    std::println("{}", c::vs_sum(&s));
    std::println("{}", @sizeof(c::vq) == c::vq_size());
}
// expect: true true true
// expect: 31
// expect: true
