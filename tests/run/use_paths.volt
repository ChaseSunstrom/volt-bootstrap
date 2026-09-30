use std::io;
use app::util;
use app::util::shout;

namespace app::util {
    fn twice(x: i32) -> i32 { return x * 2; }
    fn shout() -> void { std::println("HEY"); }
    struct pt { x: i32; }
}

fn main() -> void {
    std::println("short");
    std::io::println("full");
    std::println(app::twice(21));
    app::shout();
    val p: app::pt = { x: 1 };
    std::println(p.x);
}
// expect: short
// expect: full
// expect: 42
// expect: HEY
// expect: 1
