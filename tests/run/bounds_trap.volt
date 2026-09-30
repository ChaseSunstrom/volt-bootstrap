use std::io;
fn main() -> void {
    val arr: i32[3] = { 1, 2, 3 };
    var i: usize = 0;
    while (i < 5) {
        std::println(arr[i]);
        i++;
    }
}
// expect: 1
// expect: 2
// expect: 3
// exit: 101
