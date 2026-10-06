// a match on a reference matches what it refers to, in place: x& bindings change the referent
use std::io;
enum op { ADD, NEG: i32 }
fn show(r: op&) -> void {
    match (r) {
        .ADD => std::println("add"),
        .NEG(n) => std::println("neg {}", n),
    }
}
fn bump(r: op&) -> void {
    match (r) {
        .NEG(n&) => { *n += 1; },
        default => {},
    }
}
fn main() -> void {
    val a = op::ADD;
    var b = op::NEG(3);
    show(&a);
    bump(&b);
    show(&b);
}
// expect: add
// expect: neg 4
