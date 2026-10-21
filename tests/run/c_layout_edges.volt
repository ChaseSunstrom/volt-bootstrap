// layouts where targets differ: a packed C struct's 32-byte vector and scalars, read and written in
// place (not at their own alignment); a C union holding a 32-byte vector at C's offset in a struct;
// a Volt vector after an i32 where Volt's layout puts it; a header struct aligned past 16 aligned
// as a by-value parameter
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
    std::println("a32 {}", take(a));
}
// expect: pk true true 286
// expect: pk read 285 70
// expect: su true true 5
// expect: vv true 32 4
// expect: a32 5
