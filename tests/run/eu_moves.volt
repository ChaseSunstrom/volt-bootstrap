use std::io;
fn main() -> !void {
    val r = i32::new(1);
    val b = try r;
    std::println(b);
    val r2 = i32::new(2);
    val c = r2 catch |e| { return e; };
    std::println(c);
    val r3 = i32::new(3);
    std::println(r3.value);
}
// flags: --leak-check
// expect: 1
// expect: 2
// expect: 3
