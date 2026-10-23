// a struct member of a complex type is the import's cf64 (cf32 for float), read and written from
// Volt; a pointer to one is a cf64* C writes through (c_complex_member.h)
use std::io;
use { "c_complex_member.h" } as c;

fn main() -> void {
    var w: c::wave = { z: { re: 3.0, im: 4.0 }, n: 1, f: { re: 0.5, im: -1.5 } };
    std::println("{} {} {} {}", w.z.re, w.z.im, w.n, c::mag2(w));
    c::flip(&w);
    std::println("{} {} {} {} {}", w.z.re, w.z.im, w.n, w.f.re, w.f.im);
    var z: c::cf64 = { re: 1.5, im: -2.0 };
    c::scale(&z, 2.0);
    std::println("{} {}", z.re, z.im);
    w.z.im = 0.0;
    std::println("{}", c::mag2(w));
}
// expect: 3 4 1 25
// expect: 3 -4 2 1 -3
// expect: 3 -4
// expect: 9
