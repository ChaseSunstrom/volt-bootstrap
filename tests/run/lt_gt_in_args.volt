// `<` and `>` around a comma in a call's arguments are two comparisons, not a generic method's
// arguments: f(a.x < b, c > (d))
use std::io;

struct pt {
    x: i32;
}

fn both(p: bool, q: bool) -> str {
    if (p && q) {
        return "both";
    }
    return "not both";
}

fn main() -> void {
    val a: pt = { x: 1 };
    val b = 2;
    val c = 5;
    std::println("{}", both(a.x < b, c > (a.x + 1)));
    std::println("{}", both(a.x < b, c > (9)));
}
// expect: both
// expect: not both
