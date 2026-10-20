// flags: --release --leak-check
// an @align(32) struct on the heap: in a box, as a vec's elements while it grows (each realloc may
// move them), as a map's values; every address is a multiple of 32, over rounds that free and
// allocate again between blocks of odd sizes
use std::io;

@attributes([@align(32)])
struct wide { x: u8; y: f64; }

<T: type> fn rem(p: T*) -> usize {
    return @cast<usize>(p) % 32;
}

fn main() -> void {
    var off: usize = 0;
    var sum: f64 = 0.0;
    for (round) in 0..3 {
        var odd: std::vec<u8> = {};
        for (i) in 0..(round * 7 + 3) {
            odd.push(@cast<u8>(i)) catch @panic("out of memory");
        }
        val b = wide::new({ x: 1, y: 0.5 }) catch @panic("out of memory");
        off += rem(b.ptr);
        var v: std::vec<wide> = {};
        for (i) in 0..40 {
            v.push({ x: @cast<u8>(i), y: 1.0 }) catch @panic("out of memory");
            off += rem(&v[0]) + rem(&v[@cast<usize>(i)]);
        }
        v.reserve(200) catch @panic("out of memory");
        off += rem(&v[0]);
        var m: std::map<i32, wide> = {};
        for (i) in 0..20 {
            m.put(i, { x: 2, y: 0.25 });
        }
        for (i) in 0..20 {
            val p = m.get(i) ?? @panic("missing");
            off += rem(p);
            sum += p->y;
        }
        sum += b.y + v[39].y;
    }
    std::println("misaligned by {}", off);
    std::println("sum {}", sum);
}
// expect: misaligned by 0
// expect: sum 19.5
