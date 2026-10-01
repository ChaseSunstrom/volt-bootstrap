use std::io;
// std::random: xoshiro256** against its reference vector, splitmix64 seeding, unbiased ranges,
// floats, chance, shuffle, choose and the OS source

fn main() -> void {
    // the reference vector for state {1, 2, 3, 4}
    var r: std::random::rng = { s0: 1, s1: 2, s2: 3, s3: 4 };
    std::println("{} {} {} {}", r.next_u64(), r.next_u64(), r.next_u64(), r.next_u64());

    // seeding expands the seed with splitmix64, and the same seed gives the same numbers
    var a = std::random::seeded(42);
    var b = std::random::seeded(42);
    std::println("{} {} {}", a.s0, a.next_u64(), a.next_u64());
    var same = true;
    b.next_u64();
    b.next_u64();
    for (k) in 0..100 {
        same = same && a.next_u64() == b.next_u64();
    }
    var c = std::random::seeded(42);
    std::println("{} {} {} {} {} {}", same, c.below(100), c.below(100), c.below(100), c.below(100), c.below(100));

    // below and range stay in bounds and reach both ends; buckets come out near uniform
    var g = std::random::seeded(7);
    var buckets: i32[10];
    var lo: i64 = 100;
    var hi: i64 = -100;
    var in_range = true;
    for (k) in 0..10000 {
        buckets[@cast<usize>(g.below(10))] += 1;
        val x = g.range(-5, 5);
        in_range = in_range && x >= -5 && x < 5;
        lo = std::math::min(lo, x);
        hi = std::math::max(hi, x);
    }
    var even = true;
    for (n) in buckets {
        even = even && n > 900 && n < 1100;
    }
    std::println("{} {} {} {}", in_range, lo, hi, even);

    // floats in [0, 1) averaging a half; chance at its edges
    var sum = 0.0;
    var in_unit = true;
    for (k) in 0..10000 {
        val f = g.float();
        in_unit = in_unit && f >= 0.0 && f < 1.0;
        sum += f;
    }
    var never = false;
    var always = true;
    for (k) in 0..1000 {
        never = never || g.chance(0.0);
        always = always && g.chance(1.0);
    }
    std::println("{} {} {} {}", in_unit, sum / 10000.0 > 0.48 && sum / 10000.0 < 0.52, never, always);

    // shuffle permutes; choose picks an element (or null)
    var deck: i32[] = 0..10;
    g.shuffle(deck[..]);
    var moved = false;
    for (v, i) in deck {
        moved = moved || v != @cast<i32>(i);
    }
    deck[..].sort();
    var sorted_back = true;
    for (v, i) in deck {
        sorted_back = sorted_back && v == @cast<i32>(i);
    }
    val none: i32[0];
    val one: i32[] = { 7 };
    std::println("{} {} {} {}", moved, sorted_back, none[..].len == 0 && g.choose(none[..]) == null, *(g.choose(one[..]) ?? &one[0]));

    // the OS: two generators seeded from it differ, and its bytes aren't all zero
    var o1 = std::random::os_seeded();
    var o2 = std::random::os_seeded();
    var bytes: u8[16];
    val got = std::random::os_bytes(bytes[..]);
    var nonzero = false;
    for (x) in bytes {
        nonzero = nonzero || x != 0;
    }
    std::println("{} {} {}", o1.next_u64() != o2.next_u64(), got, nonzero);
}
// expect: 11520 0 1509978240 1215971899390074240
// expect: 13679457532755275413 1546998764402558742 6990951692964543102
// expect: true 8 37 68 92 99
// expect: true -5 4 true
// expect: true true false true
// expect: true true true 7
// expect: true true true
