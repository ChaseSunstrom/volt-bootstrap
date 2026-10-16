use std::io;
// a header struct with members Volt can't read (a bitfield, a _Complex, a long double) builds
// through LLVM: libclang places the fields Volt reads, and C passes the struct by value (a shim)
use { "c_partial.h" } as c;
// reject-stderr: building through C

struct holder {
    tag: u8;
    s: c::sample;
    f: c::five;
}

fn main() -> void {
    std::println("{} {} {} {}", @sizeof(c::sample) == c::sample_size(), @alignof(c::sample) == c::sample_align(), @sizeof(c::pair) == c::pair_size(), @sizeof(c::five) == c::five_size());
    std::println("{} {} {}", @alignof(c::five) == c::five_align(), @sizeof(c::wide) == c::wide_size(), @alignof(c::wide) == c::wide_align());
    // the fields Volt reads, and C reading every member
    var s = c::sample_make(3, 1.5);
    std::println("{} {} {} {}", s.id, s.u.code, s.weight, c::sample_total(s));
    s.id = 10;
    s.weight = 4.0;
    s.u.ratio = 0.0;
    std::println("{} {}", c::sample_total(s), c::sample_get_level(&s));
    val n = c::sample_next(s);
    std::println("{} {} {} {}", n.id, n.weight, c::sample_get_level(&n), c::sample_total(n));
    // by value both ways, in registers C chooses
    val p = c::pair_make(2.0);
    std::println("{} {}", p.x, c::pair_sum(p));
    val q = c::pair_scale(p, 3);
    std::println("{} {}", q.x, c::pair_sum(q));
    // in a Volt struct and an array
    var h: holder = { tag: 1, s: s, f: { a: 9 } };
    h.s.id += 1;
    std::println("{} {} {}", h.s.id, c::sample_total(h.s), h.f.a);
    var fs: c::five[3] = { { a: 1 }, { a: 2 }, { a: 3 } };
    for (i) in 0..3 {
        c::five_set_w(&fs[i], @cast<u32>(i) * 10);
    }
    fs[1].a = 20;
    std::println("{} {}", c::five_sum(&fs[0], 3), fs[2].a);
    val w = c::wide_make(4);
    std::println("{} {}", w.a, c::wide_get(w));
    // a member Volt skips, and fields placed by offset (an anonymous union): given by C, and
    // given to C
    val sg = c::seg_make(1.5, 2.0);
    var s2: c::seg = {};
    c::seg_set(&s2, 1.0, 4.0);
    std::println("{} {} {}", c::seg_y(&sg), c::seg_len(s2), @sizeof(c::seg));
    val v = c::v3_make(1.0);
    val u: c::v3 = { x: 2.0, y: 3.0, z: 4.0 };
    std::println("{} {} {}", v.y, v.v[2], c::v3_sum(u));
}

// expect: true true true true
// expect: true true true
// expect: 3 7 0.5 20
// expect: 23.5 5
// expect: 11 8 6 33
// expect: 2 12
// expect: 6 36
// expect: 11 24.5 9
// expect: 54 3
// expect: 4 10
// expect: 2 5 8
// expect: 2 3 9
