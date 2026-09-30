// flags: --std tests/std_alt --leak-check
use std::out;

struct node { v: i32; }
attach fn delete(this: node&) -> void { std::say("drop {}", this.v); }
attach fn bump(this: node&) -> void { this.v += 1; }

fn main() -> void {
    val a = std::heap::make<node>({ v: 7 });
    a.bump();                 // methods and fields go through the owning pointer
    std::say("v {}", a.v);
    val b = std::heap::make<i32>(5);
    std::say("{}", *b + 1);
}
// expect: v 8
// expect: 6
// expect: drop 8
