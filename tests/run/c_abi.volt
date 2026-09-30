// the C calling convention for structs by value, both ways, with C's own functions (c_abi.h):
// the C backend gets it from the C compiler, the LLVM backend has to classify each shape itself
use std::io;
use { "c_abi.h" } as c;

fn twice_li(p: c::li, k: i64) -> i64 {
    return p.a * 2 + @cast<i64>(p.b) + k;
}

fn halve_ff(p: c::ff, k: f32) -> c::ff {
    return { x: p.x / k, y: p.y * k };
}

fn bump_big(p: c::big) -> c::big {
    return { a: p.a + 1, b: p.b + 2, c: p.c + 3 };
}

fn main() -> void {
    val s = c::ii_add({ a: 1, b: 2 }, { a: 10, b: 20 });
    std::println("ii {} {}", s.a, s.b);
    val m = c::li_mix({ a: 5, b: 6 }, 3);
    std::println("li {} {}", m.a, m.b);
    val f = c::ff_scale({ x: 1.5, y: -2.0 }, 2.0);
    std::println("ff {} {}", f.x, f.y);
    val d = c::di_make(2.5, 7);
    std::println("di {} {}", d.x, d.n);
    std::println("fff {}", c::fff_sum(c::fff_make(1.5)));
    val b = c::big_add({ a: 1, b: 2, c: 3 }, { a: 10, b: 20, c: 30 });
    std::println("big {} {} {}", b.a, b.b, b.c);
    std::println("cs {}", c::cs_sum({ c: 3, s: 300 }));
    var fv: c::five = {};
    for (i) in 0..5 {
        fv.bytes[i] = @cast<u8>(i + 1);
    }
    val r = c::five_rev(fv);
    std::println("five {} {} {}", r.bytes[0], r.bytes[2], r.bytes[4]);
    std::println("many {}", c::many({ a: 1, b: 0 }, { a: 2, b: 0 }, { a: 3, b: 0 }, { a: 4, b: 5 }, 6));
    std::println("mixed {}", c::mixed(1.0, { x: 2.0, y: 3.0 }, 4, { x: 5.0, n: 6 }, 7.0));
    std::println("small {}", c::small_ints(-1, 200, 30, true));
    std::println("apply {}", c::apply(twice_li, { a: 7, b: 1 }));
    std::println("apply_ff {}", c::apply_ff(halve_ff, { x: 8.0, y: 1.0 }));
    val bb = c::apply_big(bump_big, { a: 1, b: 1, c: 1 });
    std::println("apply_big {} {} {}", bb.a, bb.b, bb.c);
    std::println("va {}", c::sum_va(3, 1.5, @cast<f32>(2.5), 3.0));
    val p1: c::ii = { a: 1, b: 2 };
    val q1: c::big = { a: 10, b: 20, c: 30 };
    val p2: c::ii = { a: 100, b: 200 };
    val q2: c::big = { a: 1000, b: 2000, c: 3000 };
    std::println("va structs {}", c::va_structs(2, p1, q1, p2, q2));
}
// expect: ii 11 22
// expect: li 15 9
// expect: ff 3 -4
// expect: di 2.5 7
// expect: fff 9
// expect: big 11 22 33
// expect: cs 303
// expect: five 5 3 1
// expect: many 21
// expect: mixed 28
// expect: small 230
// expect: apply 25
// expect: apply_ff 6
// expect: apply_big 2 3 4
// expect: va 7
// expect: va structs 6363
