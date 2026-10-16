// exit: 101
// expect-stderr: panic: heap corruption
// debug-only
use std::io;
use std::string;
use std::vec;
// a freed block's header (the allocator's magic and size, in front of it) overwritten while the block
// sits in the quarantine, as an overflow from a live neighbour would: the quarantine kept the size
// it was freed with, so the block leaving it (pushed out by 70000 later frees) is reported, not
// trusted (a size of 0 would have skipped the poison check; a huge one sent it past the block and
// the byte count below 0)

fn main() -> void {
    var v: std::vec<u64> = {};
    for (k) in 0..4 {
        v.push(@cast<u64>(k)) catch @panic("out of memory");
    }
    val stale = &v[0];
    v.push(4) catch @panic("out of memory"); // full: the elements move, the old buffer is freed
    // debug builds: std's 16-byte size header, then the runtime's {magic, size} in front of that
    val hdr = @cast<usize>(stale) - 32;
    *@cast<u64*>(hdr) = 0x4141414141414141;
    *@cast<u64*>(hdr + 8) = 0;
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
