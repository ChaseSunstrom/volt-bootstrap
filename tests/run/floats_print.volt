use std::io;
// floats print as the shortest text that reads back as the same number, in plain decimal until
// the exponent is large (or very negative)
fn main() -> void {
    std::println("{} {} {} {} {}", 1500.0, 10.0, 0.1, 2.5, 123456789.0);
    std::println("{} {} {} {}", 1e20, 1.5e-7, 0.0001, -250.0);
    val f: f32 = 0.1;
    std::println("{} {}", f, 1e15);
}
// expect: 1500 10 0.1 2.5 123456789
// expect: 1e+20 1.5e-07 0.0001 -250
// expect: 0.1 1000000000000000
