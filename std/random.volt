// std::random: pseudo-random numbers (xoshiro256**), seeded or from the operating system, and the
// OS's own secure random bytes.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace random {
    // xoshiro256** (Blackman and Vigna): fast, with good statistical quality, and the same numbers for
    // the same seed. Not for secrets (keys, tokens): use os_bytes for those
    struct rng {
        s0: u64; // the 256-bit state
        s1: u64;
        s2: u64;
        s3: u64;
    }

    internal extern "C" fn getrandom(buf: void*, len: usize, flags: u32) -> isize; // Linux, FreeBSD
    internal extern "C" fn getentropy(buf: void*, len: usize) -> i32;              // macOS: 256 bytes a call
    internal extern "C" fn rand_s(out: u32*) -> i32;                                // Windows' CRT: 4 bytes a call

    // x rotated left by k bits
    internal fn rotl(x: u64, k: u64) -> u64 {
        return (x << k) | (x >> (64 - k));
    }

    // splitmix64's next output: how xoshiro's authors recommend turning one seed into a state
    internal fn splitmix(x: u64&) -> u64 {
        *x = *x +% 0x9E3779B97F4A7C15;
        var z = *x;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    // a generator that gives the same numbers every time for the same seed
    fn seeded(seed: u64) -> rng {
        var x = seed;
        return { s0: splitmix(&x), s1: splitmix(&x), s2: splitmix(&x), s3: splitmix(&x) };
    }

    // fill buf from the operating system's secure random source; false if it can't
    fn os_bytes(buf: u8[..]) -> bool {
        var done: usize = 0;
        while (done < buf.len) {
            var left = buf.len - done;
            comptime if (@cfg("os", "windows")) {
                var word: u32 = 0;
                if (rand_s(&word) != 0) {
                    return false;
                }
                if (left > 4) {
                    left = 4;
                }
                for (i) in 0..left {
                    buf[done + i] = @cast<u8>(word >> @cast<u32>(i * 8));
                }
                done += left;
            } else if (@cfg("os", "macos")) {
                if (left > 256) {
                    left = 256;
                }
                if (getentropy(@cast<void*>(&buf[done]), left) != 0) {
                    return false;
                }
                done += left;
            } else {
                val n = getrandom(@cast<void*>(&buf[done]), left, 0);
                if (n < 0) {
                    if (platform::interrupted()) {
                        continue;
                    }
                    return false;
                }
                done += @cast<usize>(n);
            }
        }
        return true;
    }

    // a generator seeded from the operating system: different numbers every run
    fn os_seeded() -> rng {
        // the OS's bytes land in the u64s themselves (writing bytes into anything is fine; reading a
        // byte array as u64s wouldn't be: it may not be aligned for them)
        var s: u64[4];
        if (!os_bytes(@slice(@cast<u8*>(&s[0]), 32))) {
            // ponytail: no getrandom (a kernel before 3.17): the clocks, which differ per run but are guessable
            return seeded(@cast<u64>(std::time::unix_nanos()) ^ @cast<u64>(std::time::now().ns));
        }
        if ((s[0] | s[1] | s[2] | s[3]) == 0) {
            return seeded(0); // the all-zero state would only ever give zeros
        }
        return { s0: s[0], s1: s[1], s2: s[2], s3: s[3] };
    }
}

// the next 64 random bits
attach fn next_u64(this: std::random::rng&) -> u64 {
    val result = std::random::rotl(this.s1 *% 5, 7) *% 9;
    val t = this.s1 << 17;
    this.s2 ^= this.s0;
    this.s3 ^= this.s1;
    this.s1 ^= this.s2;
    this.s0 ^= this.s3;
    this.s2 ^= t;
    this.s3 = std::random::rotl(this.s3, 45);
    return result;
}

// a number in 0..n (n > 0), every one equally likely (Lemire's multiply-shift: no modulo bias)
attach fn below(this: std::random::rng&, n: u64) -> u64 {
    if (n == 0) {
        @panic("std::random: below(0) has nothing to pick from");
    }
    var m = @cast<u128>(this.next_u64()) * @cast<u128>(n);
    if (@cast<u64>(m) < n) {
        // the low half fell where some results would come up once more than others: draw again
        val t = (0 -% n) % n;
        while (@cast<u64>(m) < t) {
            m = @cast<u128>(this.next_u64()) * @cast<u128>(n);
        }
    }
    return @cast<u64>(m >> 64);
}

// an integer in lo..hi (hi excluded; lo < hi), every one equally likely
attach fn range(this: std::random::rng&, lo: i64, hi: i64) -> i64 {
    if (lo >= hi) {
        @panic("std::random: range(lo, hi) needs lo < hi");
    }
    val width = @cast<u64>(hi) -% @cast<u64>(lo);
    return lo +% @cast<i64>(this.below(width));
}

// a float in [0, 1), from the top 53 bits
attach fn float(this: std::random::rng&) -> f64 {
    return @cast<f64>(this.next_u64() >> 11) * (1.0 / 9007199254740992.0);
}

// true with probability p (0 never, 1 always)
attach fn chance(this: std::random::rng&, p: f64) -> bool {
    return this.float() < p;
}

// put xs in a random order, every order equally likely (Fisher-Yates)
<T: type>
attach fn shuffle(this: std::random::rng&, xs: T[..]) -> void {
    var i = xs.len;
    while (i > 1) {
        i -= 1;
        xs.swap(i, @cast<usize>(this.below(@cast<u64>(i + 1))));
    }
}

// a random element of xs, or null when it's empty
<T: type>
attach fn choose(this: std::random::rng&, xs: T[..]) -> T* {
    if (xs.len == 0) {
        return null;
    }
    return &xs[@cast<usize>(this.below(@cast<u64>(xs.len)))];
}
