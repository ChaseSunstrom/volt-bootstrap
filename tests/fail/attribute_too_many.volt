// a struct called as an attribute takes at most one value per field
use std::io;

namespace ser {
    struct rename {
        to: str;
    }
}

@attributes([ser::rename("a", "b")])
struct point {
    x: i32;
}

fn main() -> void {
    comptime for (a) in @typeinfo(point).attributes {
        std::println("{}", a.to);
    }
}
// error: ser::rename has 1 field(s), given 2 values
