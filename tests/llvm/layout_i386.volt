// i386 (--cfg arch=x86 --no-std, built by cc -m32 through C: golden_layout_targets): the
// compile-time layout of 8-byte ints and floats is C's, aligned to 4, so Volt's structs match the
// header's (which only C lays out) and @sizeof and @alignof at compile time agree with them
use { "layout_i386.h" } as c;

extern "C" fn printf(fmt: cstr, ...) -> i32;

struct wide {
    a: u8;
    b: i64;
}

struct dbl {
    a: u8;
    b: f64;
    c: i32;
}

// array lengths: the checker's layout, folded at compile time (an @sizeof in an expression is the C
// compiler's sizeof)
struct folded {
    wide_size: u8[@sizeof(wide)];
    wide_align: u8[@alignof(wide)];
    dbl_size: u8[@sizeof(dbl)];
    dbl_align: u8[@alignof(dbl)];
    i64_align: u8[@alignof(i64)];
    f64_align: u8[@alignof(f64)];
}

fn n(x: usize) -> i32 {
    return @cast<i32>(x);
}

fn main() -> i32 {
    var f: folded = { wide_size: {}, wide_align: {}, dbl_size: {}, dbl_align: {}, i64_align: {}, f64_align: {} };
    printf("wide %d %d / C %d %d\n", n(f.wide_size.len), n(f.wide_align.len), n(@sizeof(c::c_wide)), n(@alignof(c::c_wide)));
    printf("dbl %d %d / C %d %d\n", n(f.dbl_size.len), n(f.dbl_align.len), n(@sizeof(c::c_dbl)), n(@alignof(c::c_dbl)));
    printf("i64 %d f64 %d\n", n(f.i64_align.len), n(f.f64_align.len));
    return 0;
}
