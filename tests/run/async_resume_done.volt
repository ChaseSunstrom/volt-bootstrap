use std::io;
async fn once() -> i32 { suspend; return 1; }
fn main() -> void {
    val fr = async once();
    resume fr;          // runs to the end
    std::println("done");
    resume fr;          // nothing left to run
}
// expect: done
// exit: 101
