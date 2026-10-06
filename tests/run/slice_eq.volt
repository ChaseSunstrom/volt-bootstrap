// slices compare with eq: lengths first, integers and bools as bytes all at once, anything else
// element by element with its own eq (so 0.0 equals -0.0); vectors compare as their slices
use std::io;

struct pt { x: i32; }
attach fn eq(this: pt&, other: pt&) -> bool { return this.x == other.x; }

fn main() -> !void {
    val a: u8[] = { 1, 2, 3 };
    val b: u8[] = { 1, 2, 3 };
    val c: u8[] = { 1, 2, 4 };
    val e: u8[] = {};
    val (sa, sb, sc, se, s2) = (a[..], b[..], c[..], e[..], a[0..2]);
    std::println("{} {} {} {}", sa.eq(&sb), sa.eq(&sc), s2.eq(&sb), se.eq(&se));
    val w: i64[] = { -1, 1 << 40 };
    val x: i64[] = { -1, 1 << 40 };
    val t: bool[] = { true, false };
    val u: bool[] = { true, true };
    val (sw, sx, st, su) = (w[..], x[..], t[..], u[..]);
    std::println("{} {} {}", sw.eq(&sx), st.eq(&st), st.eq(&su));
    val f: f64[] = { 0.0, 1.0 };
    val g: f64[] = { -0.0, 1.0 };
    val (sf, sg) = (f[..], g[..]);
    std::println(sf.eq(&sg));
    val p: pt[] = { { x: 1 }, { x: 2 } };
    val q: pt[] = { { x: 1 }, { x: 3 } };
    val (sp, sq) = (p[..], q[..]);
    std::println("{} {}", sp.eq(&sp), sp.eq(&sq));
    var v: std::vec<i64> = {};
    var y: std::vec<i64> = {};
    try v.push(5);
    try y.push(5);
    std::println(v.eq(&y));
    try y.push(6);
    std::println(v.eq(&y));
}
// expect: true false false true
// expect: true true false
// expect: true
// expect: true false
// expect: true
// expect: false
