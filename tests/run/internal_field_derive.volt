// reflection sees every field: @derive(eq) works on a struct with an internal field, and a
// program's own code uses its internal fields
use std::io;

@attributes([@derive(eq)])
struct s {
    a: i32;
    internal b: i32;
}

fn main() -> void {
    val x: s = { a: 1, b: 2 };
    val y: s = { a: 1, b: 2 };
    val z: s = { a: 1, b: 3 };
    std::println("{} {} {}", x == y, x == z, x.b);
    val p = vis::make_account(1);
    val q = vis::make_account(1);
    val r = vis::make_account(2);
    std::println("{} {}", p == q, p == r);
}
// expect: true false 2
// expect: true false
// flags: --pkg vis=tests/pkgs/vis
