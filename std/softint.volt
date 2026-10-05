// std::softint: integer arithmetic a core may not have in hardware, from 32-bit operations: a
// Cortex-M0 has no divide instruction and no 32x32->64 multiply, and no 32-bit core divides 64-bit
// numbers. Nothing here uses an operation it implements, so none of it ends up calling itself
// (std/bare.volt hands these to LLVM under the names it calls, __udivsi3 and the rest).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace softint {
    // n / d, and n % d into rem; d isn't 0 (the caller checked)
    public fn udivmod32(n: u32, d: u32, rem: u32*) -> u32 {
        var q: u32 = 0;
        var r: u32 = 0;
        var i: u32 = 32;
        while (i > 0) {
            i -= 1;
            // r is below d; doubling it can carry out of 32 bits, and then it's past d for sure
            val carry = r >> 31;
            r = (r << 1) | ((n >> i) & 1);
            if (carry != 0 || r >= d) {
                r = r -% d;
                q |= @cast<u32>(1) << i;
            }
        }
        if (rem != null) {
            *rem = r;
        }
        return q;
    }

    public fn udivmod64(n: u64, d: u64, rem: u64*) -> u64 {
        var q: u64 = 0;
        var r: u64 = 0;
        var i: u32 = 64;
        while (i > 0) {
            i -= 1;
            val carry = high(r) >> 31;
            r = (r << 1) | ((n >> i) & 1);
            if (carry != 0 || r >= d) {
                r = r -% d;
                q |= @cast<u64>(1) << i;
            }
        }
        if (rem != null) {
            *rem = r;
        }
        return q;
    }

    // the signed ones through the magnitudes, wrapping so the most negative number works too: the
    // quotient truncates, the remainder takes the dividend's sign
    public fn sdivmod32(n: i32, d: i32, rem: i32*) -> i32 {
        var un = @cast<u32>(n);
        if (n < 0) {
            un = 0 -% un;
        }
        var ud = @cast<u32>(d);
        if (d < 0) {
            ud = 0 -% ud;
        }
        var ur: u32 = 0;
        var q = udivmod32(un, ud, &ur);
        if ((n < 0) != (d < 0)) {
            q = 0 -% q;
        }
        if (n < 0) {
            ur = 0 -% ur;
        }
        if (rem != null) {
            *rem = @cast<i32>(ur);
        }
        return @cast<i32>(q);
    }

    public fn sdivmod64(n: i64, d: i64, rem: i64*) -> i64 {
        var un = @cast<u64>(n);
        if (n < 0) {
            un = 0 -% un;
        }
        var ud = @cast<u64>(d);
        if (d < 0) {
            ud = 0 -% ud;
        }
        var ur: u64 = 0;
        var q = udivmod64(un, ud, &ur);
        if ((n < 0) != (d < 0)) {
            q = 0 -% q;
        }
        if (n < 0) {
            ur = 0 -% ur;
        }
        if (rem != null) {
            *rem = @cast<i64>(ur);
        }
        return @cast<i64>(q);
    }

    // a u64 from its halves, and back, through its bytes (low half first: every core voltc targets
    // is little-endian). Not by shifting: a debug build's x >> 32 is a call to lshr64 on a Cortex-M0
    public fn join(hi: u32, lo: u32) -> u64 {
        val h: u32[2] = { lo, hi };
        return @bitcast<u64>(h);
    }

    public fn high(x: u64) -> u32 {
        return @bitcast<u32[2]>(x)[1];
    }

    // x << s, x >> s and the arithmetic x >> s, for s in 0..63, through the halves
    public fn shl64(x: u64, s: u32) -> u64 {
        val (hi, lo, n) = (high(x), @cast<u32>(x), s & 63);
        if (n == 0) {
            return x;
        }
        if (n >= 32) {
            return join(lo << (n - 32), 0);
        }
        return join((hi << n) | (lo >> (32 - n)), lo << n);
    }

    public fn lshr64(x: u64, s: u32) -> u64 {
        val (hi, lo, n) = (high(x), @cast<u32>(x), s & 63);
        if (n == 0) {
            return x;
        }
        if (n >= 32) {
            return join(0, hi >> (n - 32));
        }
        return join(hi >> n, (lo >> n) | (hi << (32 - n)));
    }

    public fn ashr64(x: i64, s: u32) -> i64 {
        val (hi, lo, n) = (@cast<i32>(high(@cast<u64>(x))), @cast<u32>(@cast<u64>(x)), s & 63);
        if (n == 0) {
            return x;
        }
        if (n >= 32) {
            return @cast<i64>(join(@cast<u32>(hi >> 31), @cast<u32>(hi >> (n - 32))));
        }
        return @cast<i64>(join(@cast<u32>(hi >> n), (lo >> n) | (@cast<u32>(hi) << (32 - n))));
    }

    // the whole 64-bit product of two u32s, from their 16-bit halves (each partial product fits
    // in 32 bits). Wrapping ops, though nothing wraps: a debug build checks a u32 * for overflow
    // through a 64-bit multiply, which is a call to mul64
    public fn mul32x32(a: u32, b: u32) -> u64 {
        val (a0, a1, b0, b1) = (a & 0xFFFF, a >> 16, b & 0xFFFF, b >> 16);
        val p00 = a0 *% b0;
        val p01 = a0 *% b1;
        val p10 = a1 *% b0;
        val mid = (p00 >> 16) + (p01 & 0xFFFF) + (p10 & 0xFFFF);
        val lo = (p00 & 0xFFFF) | (mid << 16);
        val hi = a1 *% b1 + (p01 >> 16) + (p10 >> 16) + (mid >> 16);
        return join(hi, lo);
    }

    // a * b, wrapping: the high halves only reach the result's upper 32 bits
    public fn mul64(a: u64, b: u64) -> u64 {
        val (ah, al, bh, bl) = (high(a), @cast<u32>(a), high(b), @cast<u32>(b));
        val cross = al *% bh +% ah *% bl;
        return mul32x32(al, bl) +% join(cross, 0);
    }
}
