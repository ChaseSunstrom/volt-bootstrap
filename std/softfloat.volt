// std::softfloat: IEEE 754 arithmetic on the bits of floats, with integer instructions only, rounding
// to nearest with ties to even like the hardware: what a CPU without a floating-point unit uses
// (std/bare.volt hands these to LLVM under the names it calls, __adddf3 and the rest). The f64 code
// follows compiler-rt's generic soft-float; the f32 operations go through f64 and round once more,
// which gives the exact f32 result for +, -, * and / (53 bits is more than twice 24, plus two).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace softfloat {
    val SIGN: u64 = 0x8000000000000000;
    val INF: u64 = 0x7FF0000000000000;
    val FRAC: u64 = 0x000FFFFFFFFFFFFF;
    val IMPLICIT: u64 = 0x0010000000000000;
    val QUIET: u64 = 0x0008000000000000;
    val NAN: u64 = 0x7FF8000000000000;

    // the number of leading zero bits of x (64 for 0)
    fn clz64(x: u64) -> i32 {
        if (x == 0) {
            return 64;
        }
        var n: i32 = 0;
        var v = x;
        if ((v >> 32) == 0) {
            n += 32;
            v <<= 32;
        }
        if ((v >> 48) == 0) {
            n += 16;
            v <<= 16;
        }
        if ((v >> 56) == 0) {
            n += 8;
            v <<= 8;
        }
        if ((v >> 60) == 0) {
            n += 4;
            v <<= 4;
        }
        if ((v >> 62) == 0) {
            n += 2;
            v <<= 2;
        }
        if ((v >> 63) == 0) {
            n += 1;
        }
        return n;
    }

    // x >> by, with a 1 in the lowest bit when anything nonzero was shifted out ("sticky")
    fn shift_sticky(x: u64, by: i32) -> u64 {
        if (by <= 0) {
            return x;
        }
        if (by >= 64) {
            if (x != 0) {
                return 1;
            }
            return 0;
        }
        var r = x >> @cast<u64>(by);
        if ((x << @cast<u64>(64 - by)) != 0) {
            r |= 1;
        }
        return r;
    }

    // the result from its sign, biased exponent and significand: the significand's leading 1 at bit 55
    // (for exp >= 1), its low three bits the guard, round and sticky bits. Below the smallest normal
    // the significand shifts right (a subnormal, or zero); past the largest it's infinity
    fn pack64(sign: u64, exp0: i32, sig0: u64) -> u64 {
        var exp = exp0;
        var sig = sig0;
        if (exp >= 2047) {
            return sign | INF;
        }
        if (exp <= 0) {
            sig = shift_sticky(sig, 1 - exp);
            exp = 0;
        }
        val rest = sig & 7;
        var r = ((sig >> 3) & FRAC) | (@cast<u64>(exp) << 52) | sign;
        // ties to even; a carry may make the next exponent, or infinity, which is right
        if (rest > 4 || (rest == 4 && (r & 1) == 1)) {
            r += 1;
        }
        return r;
    }

    // the same for an f32: the significand's leading 1 at bit 26, three rounding bits below it
    fn pack32(sign: u32, exp0: i32, sig0: u64) -> u32 {
        var exp = exp0;
        var sig = sig0;
        if (exp >= 255) {
            return sign | 0x7F800000;
        }
        if (exp <= 0) {
            sig = shift_sticky(sig, 1 - exp);
            exp = 0;
        }
        val rest = sig & 7;
        var r = (@cast<u32>(sig >> 3) & 0x007FFFFF) | (@cast<u32>(exp) << 23) | sign;
        if (rest > 4 || (rest == 4 && (r & 1) == 1)) {
            r += 1;
        }
        return r;
    }

    fn is_nan(a: u64) -> bool {
        return (a & ~SIGN) > INF;
    }

    // a finite nonzero |a|'s significand (leading 1 at bit 52) and exponent, subnormals normalized
    // (their exponent goes to 0 or below)
    fn unpack(a: u64, sig: u64&, exp: i32&) -> void {
        val e = @cast<i32>((a >> 52) & 2047);
        val f = a & FRAC;
        if (e == 0) {
            val shift = clz64(f) - 11;
            *sig = f << @cast<u64>(shift);
            *exp = 1 - shift;
        } else {
            *sig = f | IMPLICIT;
            *exp = e;
        }
    }

    // ---- f64 ----

    fn add64(a: u64, b: u64) -> u64 {
        val a_abs = a & ~SIGN;
        val b_abs = b & ~SIGN;
        // zero, infinity or NaN
        if (a_abs == 0 || a_abs >= INF || b_abs == 0 || b_abs >= INF) {
            if (a_abs > INF) {
                return a | QUIET;
            }
            if (b_abs > INF) {
                return b | QUIET;
            }
            if (a_abs == INF) {
                if ((a ^ b) == SIGN) {
                    return NAN; // inf - inf
                }
                return a;
            }
            if (b_abs == INF) {
                return b;
            }
            if (a_abs == 0) {
                if (b_abs == 0) {
                    return a & b; // -0 only when both are
                }
                return b;
            }
            return a;
        }
        // a is the larger in magnitude
        var x = a;
        var y = b;
        if (b_abs > a_abs) {
            x = b;
            y = a;
        }
        var xs: u64 = 0;
        var xe: i32 = 0;
        var ys: u64 = 0;
        var ye: i32 = 0;
        unpack(x, &xs, &xe);
        unpack(y, &ys, &ye);
        val sign = x & SIGN;
        xs <<= 3;
        ys = shift_sticky(ys << 3, xe - ye);
        if (((x ^ y) & SIGN) != 0) {
            xs -= ys;
            if (xs == 0) {
                return 0; // a - a is +0
            }
            // cancellation: back to the leading 1 at bit 55
            val shift = clz64(xs) - 8;
            if (shift > 0) {
                xs <<= @cast<u64>(shift);
                xe -= shift;
            }
        } else {
            xs += ys;
            if ((xs >> 56) != 0) {
                xs = shift_sticky(xs, 1);
                xe += 1;
            }
        }
        return pack64(sign, xe, xs);
    }

    fn sub64(a: u64, b: u64) -> u64 {
        return add64(a, b ^ SIGN);
    }

    // the 128-bit product of a and b, from 32-bit pieces (32-bit cores have no 64-bit multiply high)
    fn mul_wide(a: u64, b: u64, hi: u64&, lo: u64&) -> void {
        val al = a & 0xFFFFFFFF;
        val ah = a >> 32;
        val bl = b & 0xFFFFFFFF;
        val bh = b >> 32;
        val ll = al * bl;
        val lh = al * bh;
        val hl = ah * bl;
        val hh = ah * bh;
        val mid = (ll >> 32) + (lh & 0xFFFFFFFF) + (hl & 0xFFFFFFFF);
        *lo = (ll & 0xFFFFFFFF) | (mid << 32);
        *hi = hh + (lh >> 32) + (hl >> 32) + (mid >> 32);
    }

    fn mul64(a: u64, b: u64) -> u64 {
        val a_abs = a & ~SIGN;
        val b_abs = b & ~SIGN;
        val sign = (a ^ b) & SIGN;
        if (a_abs == 0 || a_abs >= INF || b_abs == 0 || b_abs >= INF) {
            if (a_abs > INF) {
                return a | QUIET;
            }
            if (b_abs > INF) {
                return b | QUIET;
            }
            if (a_abs == INF) {
                if (b_abs == 0) {
                    return NAN; // inf * 0
                }
                return INF | sign;
            }
            if (b_abs == INF) {
                if (a_abs == 0) {
                    return NAN;
                }
                return INF | sign;
            }
            return sign; // a zero
        }
        var xs: u64 = 0;
        var xe: i32 = 0;
        var ys: u64 = 0;
        var ye: i32 = 0;
        unpack(a, &xs, &xe);
        unpack(b, &ys, &ye);
        // the product of two 53-bit significands has 105 or 106 bits: keep the top 56, the rest sticky
        var hi: u64 = 0;
        var lo: u64 = 0;
        mul_wide(xs, ys, &hi, &lo);
        var e = xe + ye - 1023;
        var shift: u64 = 49;
        if ((hi >> 41) != 0) {
            shift = 50;
            e += 1;
        }
        var top = (hi << (64 - shift)) | (lo >> shift);
        if ((lo << (64 - shift)) != 0) {
            top |= 1;
        }
        return pack64(sign, e, top);
    }

    fn div64(a: u64, b: u64) -> u64 {
        val a_abs = a & ~SIGN;
        val b_abs = b & ~SIGN;
        val sign = (a ^ b) & SIGN;
        if (a_abs == 0 || a_abs >= INF || b_abs == 0 || b_abs >= INF) {
            if (a_abs > INF) {
                return a | QUIET;
            }
            if (b_abs > INF) {
                return b | QUIET;
            }
            if (a_abs == INF) {
                if (b_abs == INF) {
                    return NAN; // inf / inf
                }
                return INF | sign;
            }
            if (b_abs == INF) {
                return sign; // x / inf
            }
            if (a_abs == 0) {
                if (b_abs == 0) {
                    return NAN; // 0 / 0
                }
                return sign;
            }
            return INF | sign; // x / 0
        }
        var xs: u64 = 0;
        var xe: i32 = 0;
        var ys: u64 = 0;
        var ye: i32 = 0;
        unpack(a, &xs, &xe);
        unpack(b, &ys, &ye);
        var e = xe - ye + 1023;
        if (xs < ys) {
            xs <<= 1;
            e -= 1;
        }
        // 56 quotient bits by long division (the first is always 1), the remainder sticky
        var q: u64 = 0;
        var r = xs;
        for (i) in 0..56 {
            q <<= 1;
            if (r >= ys) {
                r -= ys;
                q |= 1;
            }
            r <<= 1;
        }
        if (r != 0) {
            q |= 1;
        }
        return pack64(sign, e, q);
    }

    // -1, 0 or 1 as a is less than, equal to or greater than b; 2 when either is NaN. -0 equals 0
    fn cmp64(a: u64, b: u64) -> i32 {
        if (is_nan(a) || is_nan(b)) {
            return 2;
        }
        if (((a | b) & ~SIGN) == 0) {
            return 0;
        }
        val x = @cast<i64>(a);
        val y = @cast<i64>(b);
        if ((x & y) >= 0) {
            // both positive: the bits order like the values
            if (x < y) {
                return -1;
            }
            if (x == y) {
                return 0;
            }
            return 1;
        }
        // a negative in there: the order of the bits is backwards
        if (x > y) {
            return -1;
        }
        if (x == y) {
            return 0;
        }
        return 1;
    }

    // ---- conversions ----

    fn f32_to_f64(a: u32) -> u64 {
        val sign = @cast<u64>(a & 0x80000000) << 32;
        val e = @cast<i32>((a >> 23) & 255);
        val f = @cast<u64>(a & 0x007FFFFF);
        if (e == 255) {
            if (f != 0) {
                return sign | INF | QUIET | (f << 29); // NaN: keep its payload, quiet
            }
            return sign | INF;
        }
        if (e == 0) {
            if (f == 0) {
                return sign;
            }
            // a subnormal f32 is a normal f64
            val shift = clz64(f) - 40;
            val frac = (f << @cast<u64>(shift)) & 0x007FFFFF;
            return sign | (@cast<u64>(1 - shift - 127 + 1023) << 52) | (frac << 29);
        }
        return sign | (@cast<u64>(e - 127 + 1023) << 52) | (f << 29);
    }

    fn f64_to_f32(a: u64) -> u32 {
        val sign = @cast<u32>(a >> 32) & 0x80000000;
        val a_abs = a & ~SIGN;
        if (a_abs > INF) {
            return sign | 0x7FC00000 | @cast<u32>((a & FRAC) >> 29);
        }
        if (a_abs == INF) {
            return sign | 0x7F800000;
        }
        if (a_abs == 0) {
            return sign;
        }
        var s: u64 = 0;
        var e: i32 = 0;
        unpack(a, &s, &e);
        // 53 significand bits to 24 and three rounding bits
        return pack32(sign, e - 1023 + 127, shift_sticky(s, 26));
    }

    // an integer's magnitude, and whether it's negative, as an f64 or f32 (rounded once)
    fn u64_to_f64(neg: bool, v: u64) -> u64 {
        var sign: u64 = 0;
        if (neg) {
            sign = SIGN;
        }
        if (v == 0) {
            return sign;
        }
        // the leading 1 to bit 55
        val lead = 63 - clz64(v);
        var sig = v;
        if (lead > 55) {
            sig = shift_sticky(v, lead - 55);
        } else {
            sig = v << @cast<u64>(55 - lead);
        }
        return pack64(sign, lead + 1023, sig);
    }

    fn u64_to_f32(neg: bool, v: u64) -> u32 {
        var sign: u32 = 0;
        if (neg) {
            sign = 0x80000000;
        }
        if (v == 0) {
            return sign;
        }
        val lead = 63 - clz64(v);
        var sig = v;
        if (lead > 26) {
            sig = shift_sticky(v, lead - 26);
        } else {
            sig = v << @cast<u64>(26 - lead);
        }
        return pack32(sign, lead + 127, sig);
    }

    fn i64_to_f64(v: i64) -> u64 {
        if (v < 0) {
            return u64_to_f64(true, 0 -% @cast<u64>(v));
        }
        return u64_to_f64(false, @cast<u64>(v));
    }

    fn i64_to_f32(v: i64) -> u32 {
        if (v < 0) {
            return u64_to_f32(true, 0 -% @cast<u64>(v));
        }
        return u64_to_f32(false, @cast<u64>(v));
    }

    // a's integer part (toward zero) as an unsigned magnitude no wider than `bits`, saturating
    // past it; NaN gives the largest
    fn f64_to_magnitude(a: u64, bits: i32) -> u64 {
        val e = @cast<i32>((a >> 52) & 2047) - 1023;
        if (e < 0) {
            return 0;
        }
        if (e >= bits || is_nan(a)) {
            if (bits >= 64) {
                return 0xFFFFFFFFFFFFFFFF;
            }
            return (@cast<u64>(1) << @cast<u64>(bits)) - 1;
        }
        val s = (a & FRAC) | IMPLICIT;
        if (e >= 52) {
            return s << @cast<u64>(e - 52);
        }
        return s >> @cast<u64>(52 - e);
    }

    fn f64_to_i64(a: u64) -> i64 {
        val m = f64_to_magnitude(a, 63);
        if ((a & SIGN) != 0 && !is_nan(a)) {
            if (m == 0x7FFFFFFFFFFFFFFF && @cast<i32>((a >> 52) & 2047) - 1023 >= 63) {
                return -9223372036854775807 - 1;
            }
            return 0 - @cast<i64>(m);
        }
        return @cast<i64>(m);
    }

    fn f64_to_u64(a: u64) -> u64 {
        if ((a & SIGN) != 0) {
            return 0;
        }
        return f64_to_magnitude(a, 64);
    }

    fn f64_to_i32(a: u64) -> i32 {
        val m = f64_to_magnitude(a, 31);
        if ((a & SIGN) != 0 && !is_nan(a)) {
            if (m == 0x7FFFFFFF && @cast<i32>((a >> 52) & 2047) - 1023 >= 31) {
                return -2147483647 - 1;
            }
            return 0 - @cast<i32>(m);
        }
        return @cast<i32>(m);
    }

    fn f64_to_u32(a: u64) -> u32 {
        if ((a & SIGN) != 0) {
            return 0;
        }
        return @cast<u32>(f64_to_magnitude(a, 32));
    }

    // ---- f32: through f64, rounded once more ----

    fn add32(a: u32, b: u32) -> u32 {
        return f64_to_f32(add64(f32_to_f64(a), f32_to_f64(b)));
    }

    fn sub32(a: u32, b: u32) -> u32 {
        return f64_to_f32(sub64(f32_to_f64(a), f32_to_f64(b)));
    }

    fn mul32(a: u32, b: u32) -> u32 {
        return f64_to_f32(mul64(f32_to_f64(a), f32_to_f64(b)));
    }

    fn div32(a: u32, b: u32) -> u32 {
        return f64_to_f32(div64(f32_to_f64(a), f32_to_f64(b)));
    }

    fn cmp32(a: u32, b: u32) -> i32 {
        return cmp64(f32_to_f64(a), f32_to_f64(b));
    }
}
