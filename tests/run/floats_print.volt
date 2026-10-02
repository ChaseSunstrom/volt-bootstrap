use std::io;
// floats print as the shortest text that reads back as the same number, in plain decimal until
// the exponent is large (or very negative)
fn main() -> void {
    std::println("{} {} {} {} {}", 1500.0, 10.0, 0.1, 2.5, 123456789.0);
    std::println("{} {} {} {}", 1e20, 1.5e-7, 0.0001, -250.0);
    val f: f32 = 0.1;
    std::println("{} {}", f, 1e15);
    // the edges: the smallest and largest doubles, the smallest normal, 2^53 + 1 (not a double), a
    // power of two (whose lower neighbour is closer), negative zero
    std::println("{} {} {} {}", 5e-324, 1.7976931348623157e308, 2.2250738585072014e-308, 9007199254740993.0);
    std::println("{} {} {} {}", 0.3, 1e23, 5.960464477539063e-08, -0.0);
    // an f32 prints its own shortest digits: a whole number is them, then zeros
    val big: f32 = 2003489792.0;
    val tiny: f32 = 1e-45;
    std::println("{} {} {}", big, tiny, 1.0 / 3.0);
}
// expect: 1500 10 0.1 2.5 123456789
// expect: 1e+20 1.5e-07 0.0001 -250
// expect: 0.1 1000000000000000
// expect: 5e-324 1.7976931348623157e+308 2.2250738585072014e-308 9007199254740992
// expect: 0.3 1e+23 5.960464477539063e-08 -0
// expect: 2003489800 1e-45 0.3333333333333333
