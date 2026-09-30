// flags: tests/pkgs/extra.volt --pkg geo=tests/pkgs/geo -- one two
use std::io;

fn main() -> void {
    val r: geo::rect = { w: 3, h: 4 };
    std::println(geo::area(r));
    std::println(greeting());
    std::println(std::process::arg_count());
    std::println(std::process::arg(1) ?? "none");
    std::println(std::process::arg(2) ?? "none");
    std::println(std::process::arg(3) ?? "none");
    std::process::exit(7);
}
// expect: 24
// expect: hello from extra.volt
// expect: 3
// expect: one
// expect: two
// expect: none
// exit: 7
