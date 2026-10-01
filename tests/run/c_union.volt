use std::io;
// C unions are structs whose fields share their memory; bitfields have S_get_F and S_set_F
use { "c_union.h" } as c;

fn main() -> void {
    var n: c::number = { f: 1.0 };
    std::println("{} {}", n.i, c::number_as_float(n));
    n.i = 0x40490fdb;
    std::println("{}", n.f);
    val m = c::number_of_int(258);
    std::println("{} {} {}", m.bytes[0], m.bytes[1], @sizeof(c::number));
    var w: c::wide = { big: 0 };
    w.little = -1;
    std::println("{} {}", c::wide_big(&w), @sizeof(c::wide));
    var t: c::tagged = { kind: 2, value: { i: 7 } };
    t.extra.ratio = 0.5;
    std::println("{} {} {}", t.kind, t.value.i, c::tagged_ratio(t));
    var f: c::flags = { count: 10 };
    c::flags_set_ready(&f, 1);
    c::flags_set_level(&f, 5);
    c::flags_set_delta(&f, -3);
    std::println("{} {} {} {}", c::flags_get_ready(&f), c::flags_get_level(&f), c::flags_get_delta(&f), c::flags_total(&f));
    c::flags_set_level(&f, 9); // 3 bits: C keeps 1
    std::println("{} {}", c::flags_get_level(&f), f.count);
    var p: c::point3 = { x: 1, y: 2, z: 3 };
    p.y = 20;
    std::println("{} {}", c::point3_sum(p), @sizeof(c::point3));
}

// expect: 1065353216 1
// expect: 3.1415927
// expect: 2 1 4
// expect: 65535 8
// expect: 2 7 0.5
// expect: 1 5 -3 13
// expect: 1 10
// expect: 24 12
