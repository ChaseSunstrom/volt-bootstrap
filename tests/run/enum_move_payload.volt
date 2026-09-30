// a generic enum variant built from a moved (or temporary) owned value: the payload is checked once,
// so the move is fine and each value is deleted exactly once
use std::io;

struct res { n: i32; }
attach fn delete(this: res&) -> void { std::println("delete {}", this.n); }

<T: type>
enum maybe { SOME: T, NONE, }

fn make(n: i32) -> res { return { n: n }; }

fn main() -> void {
    val a: res = { n: 1 };
    val m = maybe::SOME(move a);
    val t = maybe::SOME(make(2));
    std::println("built");
}
// expect: built
// expect: delete 2
// expect: delete 1
