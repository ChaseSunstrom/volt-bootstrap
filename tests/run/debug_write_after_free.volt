// flags: --leak-check
// exit: 101
// expect-stderr: panic: write after free
use std::vec;
// a write through a view into a freed block (a vec's old buffer, kept across the push that moved
// the elements) is caught in debug builds: the block's 0xDD poison changed, which --leak-check
// finds at exit, checking every block still in the quarantine

fn main() -> void {
    var v: std::vec<u64> = {};
    for (k) in 0..4 {
        v.push(@cast<u64>(k)) catch @panic("out of memory");
    }
    val stale = &v[0];
    v.push(4) catch @panic("out of memory"); // full: the elements move, the old buffer is freed
    *stale = 9;
}
