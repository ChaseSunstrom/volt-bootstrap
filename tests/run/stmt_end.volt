use std::io;
// a statement starting with if/while/... ends at its '}'
fn main() -> void {
    var x: i32 = 3;
    val p = &x;
    if (x > 0) {
        x += 1;
    }
    *p = *p * 10;
    std::println(x);
}
// expect: 40
