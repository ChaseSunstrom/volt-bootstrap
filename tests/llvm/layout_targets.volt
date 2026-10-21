// the types whose alignment differs between targets (golden_layout_targets builds this for the host
// and every --target): 8- and 16-byte ints and floats and 16-byte vectors in structs, tuples, enums
// and optionals, so lgen's check_layout compares each LLVM type with the checker's layout
use std::simd;

struct wide {
    a: u8;
    b: i128;
}

struct dbl {
    a: u8;
    b: f64;
    c: i64;
    q: f128;
}

struct lanes {
    a: u8;
    v: std::simd::f32x4;
}

// 16-aligned where 32-bit ARM aligns no vector that way (lgen's aligner: an f128)
@attributes([@align(16)])
struct cell {
    a: u8;
}

enum shape {
    WIDE: wide,
    DBL: dbl,
    LANES: lanes,
    NONE,
}

fn main() -> i32 {
    val w: wide = { a: 1, b: 2 };
    val d: dbl = { a: 1, b: 2.0, c: 3, q: 1.0 };
    val l: lanes = { a: 1, v: {} };
    val c: cell = { a: 2 };
    val t = (w, d, l, @cast<u128>(5), c);
    val s = shape::DBL(d);
    var o: dbl? = d;
    o = null;
    var n = @cast<i32>(t.0.a + t.1.a + t.2.a) + @cast<i32>(@sizeof(wide) + @sizeof(dbl) + @sizeof(lanes) + @sizeof(shape));
    match (s) {
        .DBL(x) => { n += @cast<i32>(x.c); },
        default => {},
    }
    if (o == null) {
        n += 1;
    }
    return n;
}
