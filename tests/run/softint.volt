use std::io;
// std::softint (what a Cortex-M0 calls for division, 64-bit shifts and multiplies, from 32-bit
// operations) against this CPU's own, on random numbers of every width and the edges: 0, 1, the
// largest, the most negative, shifts of 0, 31, 32 and 63

var state: u64 = 88172645463325252;
fn rnd() -> u64 {
    state = state ^ (state << 13);
    state = state ^ (state >> 7);
    state = state ^ (state << 17);
    return state;
}

// a random u64, often small, often an edge
fn pick() -> u64 {
    val edges: u64[6] = { 0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF };
    return match (rnd() % 8) {
        0 => edges[rnd() % 6],
        1 => 0 -% edges[rnd() % 6],
        2 => 0x8000000000000000,
        _ => rnd() >> (rnd() % 64),
    };
}

var bad: u32 = 0;
fn same(what: str, a: u64, b: u64, got: u64, want: u64) -> void {
    if (got != want && bad < 10) {
        std::println("{} {} {}: {} not {}", what, a, b, got, want);
    }
    if (got != want) {
        bad += 1;
    }
}

fn main() -> void {
    for (_) in 0..200000 {
        val (a, b) = (pick(), pick());
        val (a32, b32) = (@cast<u32>(a), @cast<u32>(b));
        val (s, s32) = (@cast<u32>(rnd() % 64), @cast<u32>(rnd() % 32));
        same("mul64", a, b, std::softint::mul64(a, b), a *% b);
        same("mul32x32", a32, b32, std::softint::mul32x32(a32, b32), @cast<u64>(a32) * @cast<u64>(b32));
        same("shl64", a, s, std::softint::shl64(a, s), a << @cast<u64>(s));
        same("lshr64", a, s, std::softint::lshr64(a, s), a >> @cast<u64>(s));
        same("ashr64", a, s, @cast<u64>(std::softint::ashr64(@cast<i64>(a), s)), @cast<u64>(@cast<i64>(a) >> @cast<i64>(s)));
        same("shl64 by s32", a, s32, std::softint::shl64(a, s32), a << @cast<u64>(s32));
        if (b != 0) {
            var r: u64 = 0;
            same("udivmod64 q", a, b, std::softint::udivmod64(a, b, &r), a / b);
            same("udivmod64 r", a, b, r, a % b);
            // the most negative / -1 overflows i64: wrapping, it's itself
            val (sa, sb) = (@cast<i64>(a), @cast<i64>(b));
            if (!(sa == -9223372036854775807 - 1 && sb == -1)) {
                var sr: i64 = 0;
                same("sdivmod64 q", a, b, @cast<u64>(std::softint::sdivmod64(sa, sb, &sr)), @cast<u64>(sa / sb));
                same("sdivmod64 r", a, b, @cast<u64>(sr), @cast<u64>(sa % sb));
            }
        }
        if (b32 != 0) {
            var r: u32 = 0;
            same("udivmod32 q", a32, b32, std::softint::udivmod32(a32, b32, &r), a32 / b32);
            same("udivmod32 r", a32, b32, r, a32 % b32);
            val (sa, sb) = (@cast<i32>(a32), @cast<i32>(b32));
            if (!(sa == -2147483647 - 1 && sb == -1)) {
                var sr: i32 = 0;
                same("sdivmod32 q", a32, b32, @cast<u64>(@cast<u32>(std::softint::sdivmod32(sa, sb, &sr))), @cast<u64>(@cast<u32>(sa / sb)));
                same("sdivmod32 r", a32, b32, @cast<u64>(@cast<u32>(sr)), @cast<u64>(@cast<u32>(sa % sb)));
            }
        }
    }
    std::println("bad {}", bad);
}
// expect: bad 0
