// slice.sort on integers (a radix sort past 256 elements) gives the same order as sorting by cmp
// (a merge sort), for signed and unsigned types of each size, with negatives, duplicates and
// small inputs; sort_by keeps equal elements in their order
use std::io;

var seed: u64 = 88172645463325252;

fn next() -> u64 {
    seed = seed ^ (seed << 13);
    seed = seed ^ (seed >> 7);
    seed = seed ^ (seed << 17);
    return seed;
}

// sorts a copy of xs both ways; true when they agree
<T: type>
fn agrees(xs: std::vec<T>&) -> bool {
    var a = xs.copy();
    var b = xs.copy();
    a.items().sort();
    b.items().sort_by(|| (x: T&, y: T&) -> i32 { return x.cmp(y); });
    for (i) in 0..a.len {
        if (*a.at(i) != *b.at(i)) {
            return false;
        }
    }
    return true;
}

struct keyed {
    key: i32;
    tag: i32;
}

fn main() -> void {
    var ok = 0;
    val sizes: i32[] = { 10, 300, 5000 };
    for (n) in sizes {
        var i64s: std::vec<i64> = {};
        var u64s: std::vec<u64> = {};
        var i32s: std::vec<i32> = {};
        var u16s: std::vec<u16> = {};
        var i8s: std::vec<i8> = {};
        for (k) in 0..n {
            val r = next();
            i64s.push(@cast<i64>(r)) catch @panic("oom");
            u64s.push(r % 1000) catch @panic("oom");
            i32s.push(@cast<i32>(r % 2001) - 1000) catch @panic("oom");
            u16s.push(@cast<u16>(r >> 48)) catch @panic("oom");
            i8s.push(@cast<i8>(@cast<i64>(r % 256) - 128)) catch @panic("oom");
        }
        if (agrees(&i64s)) { ok += 1; }
        if (agrees(&u64s)) { ok += 1; }
        if (agrees(&i32s)) { ok += 1; }
        if (agrees(&u16s)) { ok += 1; }
        if (agrees(&i8s)) { ok += 1; }
    }
    // stability with a custom order: equal keys keep their tags' order
    var ks: std::vec<keyed> = {};
    for (k) in 0..1000 {
        ks.push({ key: @cast<i32>(next() % 10), tag: k }) catch @panic("oom");
    }
    ks.items().sort_by(|| (a: keyed&, b: keyed&) -> i32 { return a.key.cmp(&b.key); });
    var stable = true;
    for (k) in 1..ks.len {
        val p = ks.at(k - 1);
        val q = ks.at(k);
        if (p.key > q.key || (p.key == q.key && p.tag > q.tag)) {
            stable = false;
        }
    }
    std::println("{} of 15 agree, stable {}", ok, stable);
}
// flags: --leak-check
// expect: 15 of 15 agree, stable true
