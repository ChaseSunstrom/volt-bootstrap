// copying a payload-less enum that attaches delete and copy: its value is a plain integer with no
// tag field, and the copy hook makes the duplicate
use std::io;

enum handle { STDIN, STDOUT }
attach fn delete(this: handle&) -> void { std::println("close"); }
attach fn copy(this: handle&) -> handle {
    std::println("dup");
    return @read(this);
}

fn main() -> void {
    val a = handle::STDOUT;
    val b = copy a;
    std::println("{}", b == handle::STDOUT);
}
// expect: dup
// expect: true
// expect: close
// expect: close
