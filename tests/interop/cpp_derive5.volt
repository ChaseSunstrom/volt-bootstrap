// A Volt type deriving from a class whose virtual methods have types Volt has no form for: pick's
// pointer-to-member parameter comes as a void*, and the pure which (its result a pointer to member)
// throws when C++ calls it, instead of keeping Volt types from deriving
use std::io;
use { "derive5.hpp" } as cpp;

struct sq {
    side: i32;
}

attach cpp::d5::Shape -> sq {
    fn area(this, self: cpp::d5::Shape&) -> i32 { return this.side * this.side; }

    fn pick(this, self: cpp::d5::Shape&, pm: void*) -> i32 {
        if (pm == null) {
            return 0;
        }
        return 7;
    }
}

fn main() -> void {
    val s: sq = { side: 4 };
    var d = cpp::d5::Shape::derive(move s);
    std::println("used {}", cpp::d5::used(&d));
    val r = cpp::d5::try_ask(&d) catch |e| {
        std::println("ask threw");
        return;
    };
    std::println("ask {}", r);
}
