// flags: --leak-check
// moves are tracked per match arm, like per branch of an if: each arm may move the same value
use std::io;

enum pick {
    LEFT: i32,
    RIGHT: i32,
}

fn eat(s: std::string) -> usize {
    return s.len();
}

fn one(p: pick) -> usize {
    val s = std::string::from("a string long enough to allocate");
    return match (p) {
        .LEFT(n) => eat(move s),
        .RIGHT(n) => eat(move s) + 1,
    };
}

fn main() -> i32 {
    std::println("{} {}", one(pick::LEFT(1)), one(pick::RIGHT(2)));
    return 0;
}
// expect: 32 33
