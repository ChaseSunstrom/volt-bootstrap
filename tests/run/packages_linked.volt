// flags: --pkg geo=tests/pkgs/geo --pkg hold=tests/pkgs/hold --pkg geo2=tests/pkgs/geo2 --leak-check
// also run against prebuilt libstd.a, libgeo.a, libhold.a and libgeo2.a (built against libhold.a) by the
// std_linked test in tests/golden.rs: hold has a global holding a trait union, so voltc builds it
// from source instead, and geo2, which uses hold
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
    std::println("held {}", hold::fire_held());
    val t: tripler = { k: 3 };
    hold::held = { h: t, n: 7 };
    std::println("held {} {} {} {}", hold::fire_held(), hold::held.n, geo2::held_plus(1), hold::spare.n);
    std::println("twice {} {}", hold::cb(5), hold::twice(6));
}

struct tripler { k: i32; }

attach hold::hook -> tripler {
    fn fire(this, x: i32) -> i32 { return this.k * x; }
}
// expect: boxed 20
// expect: error NEGATIVE
// expect: calls 2 3
// expect: arg 1
// expect: tally 7
// expect: plugin 41
// expect: slots 8 9
// expect: held 1
// expect: held 21 7 22 1
// expect: twice 10 12
