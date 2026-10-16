// exit: 101
// expect-stderr: panic: write after free
use std::io;
use std::string;
use std::vec;
// a write through a view into a freed block is caught in debug builds when the block leaves the
// quarantine (its 0xDD poison changed): here pushed out by 70000 later frees of 300-byte strings,
// past the 65536 blocks it holds

fn main() -> void {
    var v: std::vec<u64> = {};
    for (k) in 0..4 {
        v.push(@cast<u64>(k)) catch @panic("out of memory");
    }
    val stale = &v[0];
    v.push(4) catch @panic("out of memory"); // full: the elements move, the old buffer is freed
    *stale = 9;
    var text = std::string::from("");
    for (k) in 0..300 {
        text.push('x');
    }
    for (k) in 0..70000 {
        val s = std::string::from(text.as_str());
        if (s.len() != 300) {
            std::println("bad length");
        }
    }
    std::println("not caught");
}
