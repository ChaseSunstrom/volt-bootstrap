// flags: --color always
// with colour on, a type mismatch paints just where the two types differ
use std::io;

fn widen(m: std::vec<i64>) -> std::vec<i32> {
    return m;
}

fn same(a: i32*, b: i64*) -> bool {
    return a == b;
}

fn main() -> void {}
