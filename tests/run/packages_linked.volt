// flags: --pkg geo=tests/pkgs/geo --leak-check
// also run against prebuilt libstd.a + libgeo.a by the std_linked test in tests/golden.rs
use std::io;

fn main() -> void {
    val r: geo::rect = { w: 2, h: 5 };
    val b = geo::boxed_area(r) catch |e| {
        std::println("failed {}", e);
        return;
    };
    std::println("boxed {}", b);
    val bad: geo::rect = { w: -1, h: 1 };
    val e = geo::boxed_area(bad);
    if (e.err) {
        std::println("error {}", e.err);
    }
    geo::count();
    geo::count();
    std::println("calls {} {}", geo::calls, geo::count());
    std::println("arg {}", std::process::arg_count());
}
// expect: boxed 20
// expect: error NEGATIVE
// expect: calls 2 3
// expect: arg 1
