// flags: --pkg geo=tests/pkgs/geo --leak-check
// also run against prebuilt libstd.a + libgeo.a by the std_linked test in tests/golden.rs
use std::io;

// geo's plugin trait has no attacher in geo itself (its library is built without one)
struct doubler { k: i32; }

attach geo::plugin -> doubler {
    fn run(this, x: i32) -> i32 { return this.k * x; }
}

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
    geo::tally(2);
    std::println("tally {}", geo::tally(@cast<u8>(5)));
    val d: doubler = { k: 2 };
    val p: geo::plugin = d;
    std::println("plugin {}", geo::run_plugin(&p, 20));
    val s: geo::slot = { p: p, n: 4 };
    val none: geo::slot = { p: null, n: 9 };
    std::println("slots {} {}", geo::slot_total(&s), geo::slot_total(&none));
}
// expect: boxed 20
// expect: error NEGATIVE
// expect: calls 2 3
// expect: arg 1
// expect: tally 7
// expect: plugin 41
// expect: slots 8 9
