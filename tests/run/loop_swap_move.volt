// a variable moved inside a loop is fine when it gets a new value before the next pass: the swap
// idiom, and a move into a function followed by a fresh value
use std::io;

fn text(s: str) -> std::string {
    var t: std::string = {};
    t.append(s);
    return t;
}

fn consume(s: std::string) -> usize {
    return s.len();
}

fn main() -> void {
    var a = text("a");
    var b = text("bb");
    for (i) in 0..3 {
        val c = move a;
        a = move b;
        b = c;
    }
    std::println("{} {}", a.as_str(), b.as_str());
    var total: usize = 0;
    var s = text("xyz");
    for (i) in 0..4 {
        total += consume(move s);
        s = text("abcd");
    }
    std::println("{} {}", total, s.as_str());
}
// expect: bb a
// expect: 15 abcd
