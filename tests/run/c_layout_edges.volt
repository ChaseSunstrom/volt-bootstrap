// layouts where targets differ: a packed C struct's 32-byte vector and scalars, read and written in
// place (not at their own alignment); a C union holding a 32-byte vector at C's offset in a struct;
// a Volt vector after an i32 where Volt's layout puts it; a header struct aligned past 16 aligned
// as a by-value parameter; packed, aligned and #pragma pack structs at C's sizes and offsets
use std::io;
use std::simd;
use { "c_layout_edges.h" } as c;

<T: type> fn rem(p: T*, n: usize) -> usize {
    return @cast<usize>(p) % n;
}

struct vv {
    a: i32;
    v: std::simd::i32x8;
}

fn take(a: c::a32) -> usize {
    return rem(&a, 32) + @cast<usize>(a.x[4]);
}

fn main() -> void {
    var p: c::pk = {};
    p.c = 1;
    p.s = 2;
    p.d = 3.0;
    for (i) in 0..8 {
        p.v[i] = @cast<i32>(10 * i);
    }
    std::println("pk {} {} {}", @sizeof(c::pk) == c::pk_size(), @offsetof(c::pk, v) == c::pk_off_v(), c::pk_sum(&p));
    var q: c::pk = {};
    c::pk_fill(&q);
    var t: i32 = q.s + @cast<i32>(q.d);
    for (i) in 0..8 {
        t += q.v[i];
    }
    val whole = q.v;
    std::println("pk read {} {}", t, whole[7]);
    var s: c::su = {};
    s.u.v[7] = 5;
    std::println("su {} {} {}", @offsetof(c::su, u) == c::su_off_u(), @sizeof(c::su) == c::su_size(), c::su_get(&s));
    var w: vv = { a: 1, v: {} };
    w.v[3] = 4;
    std::println("vv {} {} {}", @cast<usize>(&w.v) - @cast<usize>(&w) == @offsetof(vv, v), @offsetof(vv, v), w.v[3]);
    var a: c::a32 = {};
    a.x[4] = 5;
    std::println("a32 {} {}", take(a), @sizeof(c::a32) == c::a32_size());
    var p1: c::p1 = {};
    p1.c = 1;
    p1.x = 20;
    var a8: c::a8 = {};
    a8.x = 300;
    var m1: c::m1 = {};
    m1.c = 2;
    m1.x = 4000;
    var pp: c::pp = {};
    pp.c = 3;
    pp.x = 50000;
    pp.y = 600;
    std::println("attrs {} {} {} {}", @sizeof(c::p1) == c::p1_size(), @sizeof(c::a8) == c::a8_size(), @sizeof(c::m1) == c::m1_size(), @sizeof(c::pp) == c::pp_size());
    std::println("attrs {}", c::attr_sum(&p1, &a8, &m1, &pp));
    val back = c::p1_make(900);
    std::println("by value {} {} {}", c::p1_take(p1), back.c, back.x);
    // a volatile store into a packed member (the 32-byte vector at offset 1)
    var lanes: std::simd::i32x8 = {};
    lanes[0] = 9;
    @volatile_write(&q.v, lanes);
    std::println("volatile {}", @volatile_read(&q.v)[0]);
}
// expect: pk true true 286
// expect: pk read 285 70
// expect: su true true 5
// expect: vv true 32 4
// expect: a32 5 true
// expect: attrs true true true true
// expect: attrs 54926
// expect: by value 21 7 900
// expect: volatile 9
