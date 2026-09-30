use std::io;
use std::fmt;
// std::format builds a std::string; std::write formats into anything that attaches
// write_str(this: T&, s: str) -> void: a std::string, or a type of your own

struct counter {
    bytes: usize = 0;
    calls: usize = 0;
}

attach fn write_str(this: counter&, s: str) -> void {
    this.bytes += s.len;
    this.calls += 1;
}

struct point {
    x: i32;
    y: i32;
}

fn main() -> void {
    val s = std::format("{}-{:03}", "id", 7);
    var t: std::string = {};
    val p: point = { x: 1, y: 2 };
    val xs: i32[] = { 1, 2 };
    std::write(&t, "p={} xs={}", p, xs);
    std::write(&t, "; {:.1}", 0.25);
    var c: counter = {};
    std::write(&c, "{:>10}|{}", "abc", 12345);
    val words = std::format("{} words, {}", 3, true);
    std::println("{} | {} | {} {} | {} {}", s, t, c.bytes, c.calls > 0, words, words.len());
    std::eprintln("stderr {:>4}", 1);
    // long results: a float with a big precision, a wide fill
    std::println("{} {} {}", std::format("{:.400}", 1e300).len(), std::format("{:.600e}", 1.5).len(), std::format("{:*>1000}", "x").len());
}
// expect: id-007 | p=point { x: 1, y: 2 } xs={ 1, 2 }; 0.2 | 16 true | 3 words, true 13
// expect: 702 604 1000
