// flags: --leak-check
use std::io;
use std::string;
use std::vec;
// debug builds poison a freed block with 0xDD bytes and keep it out of reuse for a long while: a
// view into a vec's first buffer, kept across the push that moved the elements, still reads the
// poison after 10000 strings were allocated and freed and blocks the old buffer's size allocated
// again (a block that went back to malloc would hold one of them now: 7s)

fn main() -> void {
    var v: std::vec<u64> = {};
    for (k) in 0..4 {
        v.push(@cast<u64>(k)) catch @panic("out of memory");
    }
    val stale = &v[0];
    v.push(4) catch @panic("out of memory"); // full: the elements move, the old buffer is freed
    var text = std::string::from("");
    for (k) in 0..200 {
        text.push('x');
    }
    for (k) in 0..10000 {
        val s = std::string::from(text.as_str());
        if (s.len() != 200) {
            std::println("bad length");
        }
    }
    var same: std::vec<std::vec<u64>> = {};
    for (k) in 0..300 {
        var b: std::vec<u64> = {};
        for (j) in 0..4 {
            b.push(7) catch @panic("out of memory");
        }
        same.push(move b) catch @panic("out of memory");
    }
    std::println("{} {}", *stale == 0xDDDDDDDDDDDDDDDD, v[4]);
}
// expect: true 4
