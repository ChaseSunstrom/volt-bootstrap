// std::softfloat: IEEE 754 arithmetic on the bits of floats, with integer instructions only, rounding
// to nearest with ties to even like the hardware: what a CPU without a floating-point unit uses
// (std/bare.volt hands these to LLVM under the names it calls, __adddf3 and the rest). The f64 code
// follows compiler-rt's generic soft-float; the f32 operations go through f64 and round once more,
// which gives the exact f32 result for +, -, * and / (53 bits is more than twice 24, plus two).
// The f128 operations are the f64 ones on u128 bits; on aarch64 macOS, whose C runtime has no quad
// routines, and on os=none, which has no C runtime, they're exported under compiler-rt's names
// (namespace quad_rt, at the end).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace softfloat {
    public val SIGN: u64 = 0x8000000000000000;
    public val INF: u64 = 0x7FF0000000000000;
    public val FRAC: u64 = 0x000FFFFFFFFFFFFF;
    public val IMPLICIT: u64 = 0x0010000000000000;
    public val QUIET: u64 = 0x0008000000000000;
    public val NAN: u64 = 0x7FF8000000000000;

    // the number of leading zero bits of x (64 for 0)
    public fn clz64(x: u64) -> i32 {
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
    public fn shift_sticky(x: u64, by: i32) -> u64 {
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
    public fn pack64(sign: u64, exp0: i32, sig0: u64) -> u64 {
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
    public fn pack32(sign: u32, exp0: i32, sig0: u64) -> u32 {
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

    public fn is_nan(a: u64) -> bool {
        return (a & ~SIGN) > INF;
    }

    // a finite nonzero |a|'s significand (leading 1 at bit 52) and exponent, subnormals normalized
    // (their exponent goes to 0 or below)
    public fn unpack(a: u64, sig: u64&, exp: i32&) -> void {
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

    public fn add64(a: u64, b: u64) -> u64 {
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

    public fn sub64(a: u64, b: u64) -> u64 {
        return add64(a, b ^ SIGN);
    }

    // the 128-bit product of a and b, from 32-bit pieces (32-bit cores have no 64-bit multiply high)
    public fn mul_wide(a: u64, b: u64, hi: u64&, lo: u64&) -> void {
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

    public fn mul64(a: u64, b: u64) -> u64 {
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

    public fn div64(a: u64, b: u64) -> u64 {
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
    public fn cmp64(a: u64, b: u64) -> i32 {
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

    public fn f32_to_f64(a: u32) -> u64 {
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

    public fn f64_to_f32(a: u64) -> u32 {
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
    public fn u64_to_f64(neg: bool, v: u64) -> u64 {
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

    public fn u64_to_f32(neg: bool, v: u64) -> u32 {
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

    public fn i64_to_f64(v: i64) -> u64 {
        if (v < 0) {
            return u64_to_f64(true, 0 -% @cast<u64>(v));
        }
        return u64_to_f64(false, @cast<u64>(v));
    }

    public fn i64_to_f32(v: i64) -> u32 {
        if (v < 0) {
            return u64_to_f32(true, 0 -% @cast<u64>(v));
        }
        return u64_to_f32(false, @cast<u64>(v));
    }

    // a's integer part (toward zero) as an unsigned magnitude no wider than `bits`, saturating
    // past it; NaN gives the largest
    public fn f64_to_magnitude(a: u64, bits: i32) -> u64 {
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

    public fn f64_to_i64(a: u64) -> i64 {
        val m = f64_to_magnitude(a, 63);
        if ((a & SIGN) != 0 && !is_nan(a)) {
            if (m == 0x7FFFFFFFFFFFFFFF && @cast<i32>((a >> 52) & 2047) - 1023 >= 63) {
                return -9223372036854775807 - 1;
            }
            return 0 - @cast<i64>(m);
        }
        return @cast<i64>(m);
    }

    public fn f64_to_u64(a: u64) -> u64 {
        if ((a & SIGN) != 0) {
            return 0;
        }
        return f64_to_magnitude(a, 64);
    }

    public fn f64_to_i32(a: u64) -> i32 {
        val m = f64_to_magnitude(a, 31);
        if ((a & SIGN) != 0 && !is_nan(a)) {
            if (m == 0x7FFFFFFF && @cast<i32>((a >> 52) & 2047) - 1023 >= 31) {
                return -2147483647 - 1;
            }
            return 0 - @cast<i32>(m);
        }
        return @cast<i32>(m);
    }

    public fn f64_to_u32(a: u64) -> u32 {
        if ((a & SIGN) != 0) {
            return 0;
        }
        return @cast<u32>(f64_to_magnitude(a, 32));
    }

    // ---- f32: through f64, rounded once more ----

    public fn add32(a: u32, b: u32) -> u32 {
        return f64_to_f32(add64(f32_to_f64(a), f32_to_f64(b)));
    }

    public fn sub32(a: u32, b: u32) -> u32 {
        return f64_to_f32(sub64(f32_to_f64(a), f32_to_f64(b)));
    }

    public fn mul32(a: u32, b: u32) -> u32 {
        return f64_to_f32(mul64(f32_to_f64(a), f32_to_f64(b)));
    }

    public fn div32(a: u32, b: u32) -> u32 {
        return f64_to_f32(div64(f32_to_f64(a), f32_to_f64(b)));
    }

    public fn cmp32(a: u32, b: u32) -> i32 {
        return cmp64(f32_to_f64(a), f32_to_f64(b));
    }

    // ---- f128 (IEEE binary128: sign, 15-bit exponent, 112-bit fraction), on its u128 bits ----

    public val Q_ABS: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // all but the sign: the sign is ~Q_ABS
    public val Q_INF: u128 = 0x7FFF0000000000000000000000000000;
    public val Q_FRAC: u128 = 0x0000FFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    public val Q_IMPLICIT: u128 = 0x00010000000000000000000000000000;
    public val Q_QUIET: u128 = 0x00008000000000000000000000000000;
    public val Q_NAN: u128 = 0x7FFF8000000000000000000000000000;

    public fn clz128(x: u128) -> i32 {
        val hi = @cast<u64>(x >> 64);
        if (hi != 0) {
            return clz64(hi);
        }
        return 64 + clz64(@cast<u64>(x));
    }

    public fn shift_sticky128(x: u128, by: i32) -> u128 {
        if (by <= 0) {
            return x;
        }
        if (by >= 128) {
            if (x != 0) {
                return 1;
            }
            return 0;
        }
        var r = x >> @cast<u128>(by);
        if ((x << @cast<u128>(128 - by)) != 0) {
            r |= 1;
        }
        return r;
    }

    // pack64's f128 twin: the significand's leading 1 at bit 115, three rounding bits below it
    public fn pack128(sign: u128, exp0: i32, sig0: u128) -> u128 {
        var exp = exp0;
        var sig = sig0;
        if (exp >= 32767) {
            return sign | Q_INF;
        }
        if (exp <= 0) {
            sig = shift_sticky128(sig, 1 - exp);
            exp = 0;
        }
        val rest = sig & 7;
        var r = ((sig >> 3) & Q_FRAC) | (@cast<u128>(exp) << 112) | sign;
        if (rest > 4 || (rest == 4 && (r & 1) == 1)) {
            r += 1;
        }
        return r;
    }

    public fn is_nan128(a: u128) -> bool {
        return (a & Q_ABS) > Q_INF;
    }

    // a finite nonzero |a|'s significand (leading 1 at bit 112) and exponent, subnormals normalized
    public fn unpack128(a: u128, sig: u128&, exp: i32&) -> void {
        val e = @cast<i32>((a >> 112) & 32767);
        val f = a & Q_FRAC;
        if (e == 0) {
            val shift = clz128(f) - 15;
            *sig = f << @cast<u128>(shift);
            *exp = 1 - shift;
        } else {
            *sig = f | Q_IMPLICIT;
            *exp = e;
        }
    }

    public fn add128(a: u128, b: u128) -> u128 {
        val a_abs = a & Q_ABS;
        val b_abs = b & Q_ABS;
        if (a_abs == 0 || a_abs >= Q_INF || b_abs == 0 || b_abs >= Q_INF) {
            if (a_abs > Q_INF) {
                return a | Q_QUIET;
            }
            if (b_abs > Q_INF) {
                return b | Q_QUIET;
            }
            if (a_abs == Q_INF) {
                if ((a ^ b) == ~Q_ABS) {
                    return Q_NAN; // inf - inf
                }
                return a;
            }
            if (b_abs == Q_INF) {
                return b;
            }
            if (a_abs == 0) {
                if (b_abs == 0) {
                    return a & b;
                }
                return b;
            }
            return a;
        }
        var x = a;
        var y = b;
        if (b_abs > a_abs) {
            x = b;
            y = a;
        }
        var xs: u128 = 0;
        var xe: i32 = 0;
        var ys: u128 = 0;
        var ye: i32 = 0;
        unpack128(x, &xs, &xe);
        unpack128(y, &ys, &ye);
        val sign = x & ~Q_ABS;
        xs <<= 3;
        ys = shift_sticky128(ys << 3, xe - ye);
        if (((x ^ y) & ~Q_ABS) != 0) {
            xs -= ys;
            if (xs == 0) {
                return 0;
            }
            val shift = clz128(xs) - 12;
            if (shift > 0) {
                xs <<= @cast<u128>(shift);
                xe -= shift;
            }
        } else {
            xs += ys;
            if ((xs >> 116) != 0) {
                xs = shift_sticky128(xs, 1);
                xe += 1;
            }
        }
        return pack128(sign, xe, xs);
    }

    public fn sub128(a: u128, b: u128) -> u128 {
        return add128(a, b ^ ~Q_ABS);
    }

    // the 64-bit halves' product as a u128 (from mul_wide: no 128-bit multiply needed)
    public fn mul_wide64(a: u64, b: u64) -> u128 {
        var hi: u64 = 0;
        var lo: u64 = 0;
        mul_wide(a, b, &hi, &lo);
        return (@cast<u128>(hi) << 64) | @cast<u128>(lo);
    }

    public fn mul128(a: u128, b: u128) -> u128 {
        val a_abs = a & Q_ABS;
        val b_abs = b & Q_ABS;
        val sign = (a ^ b) & ~Q_ABS;
        if (a_abs == 0 || a_abs >= Q_INF || b_abs == 0 || b_abs >= Q_INF) {
            if (a_abs > Q_INF) {
                return a | Q_QUIET;
            }
            if (b_abs > Q_INF) {
                return b | Q_QUIET;
            }
            if (a_abs == Q_INF) {
                if (b_abs == 0) {
                    return Q_NAN; // inf * 0
                }
                return Q_INF | sign;
            }
            if (b_abs == Q_INF) {
                if (a_abs == 0) {
                    return Q_NAN;
                }
                return Q_INF | sign;
            }
            return sign;
        }
        var xs: u128 = 0;
        var xe: i32 = 0;
        var ys: u128 = 0;
        var ye: i32 = 0;
        unpack128(a, &xs, &xe);
        unpack128(b, &ys, &ye);
        // the 225- or 226-bit product of two 113-bit significands, from 64-bit pieces
        val x0 = @cast<u64>(xs);
        val x1 = @cast<u64>(xs >> 64);
        val y0 = @cast<u64>(ys);
        val y1 = @cast<u64>(ys >> 64);
        val m: u128 = 0xFFFFFFFFFFFFFFFF;
        val p00 = mul_wide64(x0, y0);
        val p01 = mul_wide64(x0, y1);
        val p10 = mul_wide64(x1, y0);
        val p11 = mul_wide64(x1, y1);
        val mid = (p00 >> 64) + (p01 & m) + (p10 & m);
        val lo = (p00 & m) | (mid << 64);
        val hi = p11 + (p01 >> 64) + (p10 >> 64) + (mid >> 64);
        // keep the top 116 bits (leading 1 at 115), the rest sticky
        var e = xe + ye - 16383;
        var shift: u128 = 109;
        if ((hi >> 97) != 0) {
            shift = 110;
            e += 1;
        }
        var top = (hi << (128 - shift)) | (lo >> shift);
        if ((lo << (128 - shift)) != 0) {
            top |= 1;
        }
        return pack128(sign, e, top);
    }

    public fn div128(a: u128, b: u128) -> u128 {
        val a_abs = a & Q_ABS;
        val b_abs = b & Q_ABS;
        val sign = (a ^ b) & ~Q_ABS;
        if (a_abs == 0 || a_abs >= Q_INF || b_abs == 0 || b_abs >= Q_INF) {
            if (a_abs > Q_INF) {
                return a | Q_QUIET;
            }
            if (b_abs > Q_INF) {
                return b | Q_QUIET;
            }
            if (a_abs == Q_INF) {
                if (b_abs == Q_INF) {
                    return Q_NAN; // inf / inf
                }
                return Q_INF | sign;
            }
            if (b_abs == Q_INF) {
                return sign;
            }
            if (a_abs == 0) {
                if (b_abs == 0) {
                    return Q_NAN; // 0 / 0
                }
                return sign;
            }
            return Q_INF | sign; // x / 0
        }
        var xs: u128 = 0;
        var xe: i32 = 0;
        var ys: u128 = 0;
        var ye: i32 = 0;
        unpack128(a, &xs, &xe);
        unpack128(b, &ys, &ye);
        var e = xe - ye + 16383;
        if (xs < ys) {
            xs <<= 1;
            e -= 1;
        }
        // 116 quotient bits by long division, the remainder sticky
        var q: u128 = 0;
        var r = xs;
        for (i) in 0..116 {
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
        return pack128(sign, e, q);
    }

    // -1, 0 or 1 as a is less than, equal to or greater than b; 2 when either is NaN
    public fn cmp128(a: u128, b: u128) -> i32 {
        if (is_nan128(a) || is_nan128(b)) {
            return 2;
        }
        if (((a | b) & Q_ABS) == 0) {
            return 0;
        }
        val x = @cast<i128>(a);
        val y = @cast<i128>(b);
        if ((x & y) >= 0) {
            if (x < y) {
                return -1;
            }
            if (x == y) {
                return 0;
            }
            return 1;
        }
        if (x > y) {
            return -1;
        }
        if (x == y) {
            return 0;
        }
        return 1;
    }

    // a narrower float's bits (f16, f32 or f64: `fbits` fraction bits under `ebits` exponent bits)
    // as an f128, exactly; a NaN keeps its payload, quieted
    public fn widen128(a: u64, fbits: i32, ebits: i32) -> u128 {
        val emax = (1 << ebits) - 1;
        val bias = emax >> 1;
        val sign = @cast<u128>((a >> @cast<u64>(fbits + ebits)) & 1) << 127;
        val e = @cast<i32>((a >> @cast<u64>(fbits)) & @cast<u64>(emax));
        val f = a & ((@cast<u64>(1) << @cast<u64>(fbits)) - 1);
        val up = @cast<u128>(112 - fbits);
        if (e == emax) {
            if (f != 0) {
                return sign | Q_NAN | (@cast<u128>(f) << up);
            }
            return sign | Q_INF;
        }
        if (e == 0) {
            if (f == 0) {
                return sign;
            }
            // a subnormal is a normal f128
            val lead = 63 - clz64(f);
            val frac = (@cast<u128>(f) << @cast<u128>(112 - lead)) & Q_FRAC;
            return sign | (@cast<u128>(lead - fbits + 1 - bias + 16383) << 112) | frac;
        }
        return sign | (@cast<u128>(e - bias + 16383) << 112) | (@cast<u128>(f) << up);
    }

    // an f128 rounded to a narrower float (widen128's parameters), its bits in the low end of a u64
    public fn narrow128(a: u128, fbits: i32, ebits: i32) -> u64 {
        val emax = (1 << ebits) - 1;
        val bias = emax >> 1;
        val sign = @cast<u64>(a >> 127) << @cast<u64>(fbits + ebits);
        val inf = @cast<u64>(emax) << @cast<u64>(fbits);
        val fmask = (@cast<u64>(1) << @cast<u64>(fbits)) - 1;
        val a_abs = a & Q_ABS;
        if (a_abs > Q_INF) {
            val quiet = @cast<u64>(1) << @cast<u64>(fbits - 1);
            return sign | inf | quiet | @cast<u64>((a & Q_FRAC) >> @cast<u128>(112 - fbits));
        }
        if (a_abs == Q_INF) {
            return sign | inf;
        }
        if (a_abs == 0) {
            return sign;
        }
        var s: u128 = 0;
        var e: i32 = 0;
        unpack128(a, &s, &e);
        // to fbits + 1 significand bits and three rounding bits, then pack64's rounding
        var sig = @cast<u64>(shift_sticky128(s, 112 - fbits - 3));
        var exp = e - 16383 + bias;
        if (exp >= emax) {
            return sign | inf;
        }
        if (exp <= 0) {
            sig = shift_sticky(sig, 1 - exp);
            exp = 0;
        }
        val rest = sig & 7;
        var r = ((sig >> 3) & fmask) | (@cast<u64>(exp) << @cast<u64>(fbits)) | sign;
        if (rest > 4 || (rest == 4 && (r & 1) == 1)) {
            r += 1;
        }
        return r;
    }

    public fn f16_to_f128(a: u16) -> u128 { return widen128(@cast<u64>(a), 10, 5); }
    public fn f32_to_f128(a: u32) -> u128 { return widen128(@cast<u64>(a), 23, 8); }
    public fn f64_to_f128(a: u64) -> u128 { return widen128(a, 52, 11); }
    public fn f128_to_f16(a: u128) -> u16 { return @cast<u16>(narrow128(a, 10, 5)); }
    public fn f128_to_f32(a: u128) -> u32 { return @cast<u32>(narrow128(a, 23, 8)); }
    public fn f128_to_f64(a: u128) -> u64 { return narrow128(a, 52, 11); }

    // an integer's magnitude, and whether it's negative, as an f128 (exact up to 113 bits)
    public fn u128_to_f128(neg: bool, v: u128) -> u128 {
        var sign: u128 = 0;
        if (neg) {
            sign = ~Q_ABS;
        }
        if (v == 0) {
            return sign;
        }
        val lead = 127 - clz128(v);
        var sig = v;
        if (lead > 115) {
            sig = shift_sticky128(v, lead - 115);
        } else {
            sig = v << @cast<u128>(115 - lead);
        }
        return pack128(sign, lead + 16383, sig);
    }

    public fn i128_to_f128(v: i128) -> u128 {
        if (v < 0) {
            return u128_to_f128(true, 0 -% @cast<u128>(v));
        }
        return u128_to_f128(false, @cast<u128>(v));
    }

    // a's integer part (toward zero) as an unsigned magnitude no wider than `bits`, saturating
    // past it; NaN gives the largest
    public fn f128_to_magnitude(a: u128, bits: i32) -> u128 {
        val e = @cast<i32>((a >> 112) & 32767) - 16383;
        if (e < 0) {
            return 0;
        }
        if (e >= bits || is_nan128(a)) {
            if (bits >= 128) {
                return ~@cast<u128>(0);
            }
            return (@cast<u128>(1) << @cast<u128>(bits)) - 1;
        }
        val s = (a & Q_FRAC) | Q_IMPLICIT;
        if (e >= 112) {
            return s << @cast<u128>(e - 112);
        }
        return s >> @cast<u128>(112 - e);
    }

    // to a signed integer of `bits` bits (32, 64 or 128), saturating by the sign bit as
    // compiler-rt does: a NaN gives the largest, or the smallest when its sign bit is set
    public fn f128_to_signed(a: u128, bits: i32) -> i128 {
        val m = f128_to_magnitude(a, bits - 1);
        if ((a & ~Q_ABS) != 0) {
            if (@cast<i32>((a >> 112) & 32767) - 16383 >= bits - 1) {
                return 0 - @cast<i128>(m) - 1; // the smallest: -2^(bits-1)
            }
            return 0 - @cast<i128>(m);
        }
        return @cast<i128>(m);
    }

    public fn f128_to_unsigned(a: u128, bits: i32) -> u128 {
        if ((a & ~Q_ABS) != 0) {
            return 0;
        }
        return f128_to_magnitude(a, bits);
    }

    // the remainder of a / b with a's sign, exact (C's fmod, which can't round: the remainder is a
    // binary128 itself): the significands reduced a bit of the exponent gap at a time by shifting and
    // subtracting (no 128-bit division, which bare metal doesn't have), stopping early at a zero
    // remainder; at most about 32900 steps for the widest gap
    public fn rem128(a: u128, b: u128) -> u128 {
        val a_abs = a & Q_ABS;
        val b_abs = b & Q_ABS;
        if (a_abs > Q_INF) {
            return a | Q_QUIET;
        }
        if (b_abs > Q_INF) {
            return b | Q_QUIET;
        }
        if (a_abs == Q_INF || b_abs == 0) {
            return Q_NAN;
        }
        if (b_abs == Q_INF || a_abs < b_abs) {
            return a;
        }
        var xs: u128 = 0;
        var xe: i32 = 0;
        var ys: u128 = 0;
        var ye: i32 = 0;
        unpack128(a, &xs, &xe);
        unpack128(b, &ys, &ye);
        // both have their leading 1 at bit 112, so xs < 2 * ys: one subtraction, then one a bit
        var r = xs;
        if (r >= ys) {
            r -= ys;
        }
        var gap = xe - ye;
        while (gap > 0 && r != 0) {
            r <<= 1;
            if (r >= ys) {
                r -= ys;
            }
            gap -= 1;
        }
        val sign = a & ~Q_ABS;
        if (r == 0) {
            return sign;
        }
        // r * 2^(ye - 16383 - 112), its leading 1 moved to bit 115 for pack128 (no bits lost)
        val s = clz128(r) - 12;
        return pack128(sign, ye + 3 - s, r << @cast<u128>(s));
    }

    // f128 % for both backends (voltc calls it for every f128 remainder, on every target)
    export fn volt_f128_rem(x: f128, y: f128) -> f128 {
        return @bitcast<f128>(rem128(@bitcast<u128>(x), @bitcast<u128>(y)));
    }

    // ---- an f128 literal's value: decimal text to the nearest binary128 ----

    // big unsigned integers for it, 32 bits a limb, the least significant first, no zero limbs on top
    fn big_mul_add(x: std::vec<u32>&, m: u32, a: u32) -> void {
        var carry = @cast<u64>(a);
        for (i) in 0..x.len {
            val t = @cast<u64>(*x.at(i)) * @cast<u64>(m) + carry;
            *x.at(i) = @cast<u32>(t & 0xFFFFFFFF);
            carry = t >> 32;
        }
        if (carry != 0) {
            x.push(@cast<u32>(carry)) catch @panic("out of memory");
        }
    }

    fn big_bits(x: std::vec<u32>&) -> i32 {
        if (x.len == 0) {
            return 0;
        }
        return @cast<i32>(x.len) * 32 - (clz64(@cast<u64>(*x.at(x.len - 1))) - 32);
    }

    fn big_shl(x: std::vec<u32>&, s: i32) -> std::vec<u32> {
        var out: std::vec<u32> = {};
        for (i) in 0..s / 32 {
            out.push(0) catch @panic("out of memory");
        }
        val bits = @cast<u32>(s % 32);
        var carry: u32 = 0;
        for (i) in 0..x.len {
            val v = *x.at(i);
            if (bits == 0) {
                out.push(v) catch @panic("out of memory");
            } else {
                out.push((v << bits) | carry) catch @panic("out of memory");
                carry = v >> (32 - bits);
            }
        }
        if (carry != 0) {
            out.push(carry) catch @panic("out of memory");
        }
        return out;
    }

    fn big_shr1(x: std::vec<u32>&) -> void {
        var i = x.len;
        var carry: u32 = 0;
        while (i > 0) {
            i -= 1;
            val v = *x.at(i);
            *x.at(i) = (v >> 1) | carry;
            carry = v << 31;
        }
        while (x.len > 0 && *x.at(x.len - 1) == 0) {
            x.truncate(x.len - 1);
        }
    }

    fn big_cmp(a: std::vec<u32>&, b: std::vec<u32>&) -> i32 {
        if (a.len != b.len) {
            if (a.len < b.len) {
                return -1;
            }
            return 1;
        }
        var i = a.len;
        while (i > 0) {
            i -= 1;
            if (*a.at(i) != *b.at(i)) {
                if (*a.at(i) < *b.at(i)) {
                    return -1;
                }
                return 1;
            }
        }
        return 0;
    }

    // a -= b, a >= b
    fn big_sub(a: std::vec<u32>&, b: std::vec<u32>&) -> void {
        var borrow: u64 = 0;
        for (i) in 0..a.len {
            var bv: u64 = 0;
            if (i < b.len) {
                bv = @cast<u64>(*b.at(i));
            }
            val av = @cast<u64>(*a.at(i));
            if (av >= bv + borrow) {
                *a.at(i) = @cast<u32>(av - bv - borrow);
                borrow = 0;
            } else {
                *a.at(i) = @cast<u32>(av + 0x100000000 - bv - borrow);
                borrow = 1;
            }
        }
        while (a.len > 0 && *a.at(a.len - 1) == 0) {
            a.truncate(a.len - 1);
        }
    }

    // the binary128 nearest the unsigned decimal number text spells (digits, _ between them, an
    // optional fraction and e/E exponent), ties to even: num / den exactly, its quotient taken to 116
    // or 117 bits by long division, the remainder sticky, and pack128 rounding (subnormals, inf)
    public fn parse128(text: str) -> u128 {
        var num: std::vec<u32> = {};
        var exp10: i64 = 0;
        var digits: i64 = 0;
        var frac = false;
        // past 12000 significant digits (more than the ~11564 a binary128 halfway case can need)
        // a digit only moves the point or says the tail isn't 0
        var sticky = false;
        var i: usize = 0;
        while (i < text.len) {
            val c = text[i];
            if (c == '.') {
                frac = true;
            } else if (c >= '0' && c <= '9' && digits >= 12000) {
                sticky = sticky || c != '0';
                if (!frac) {
                    exp10 += 1;
                }
            } else if (c >= '0' && c <= '9') {
                big_mul_add(&num, 10, @cast<u32>(c - '0'));
                if (num.len > 0) {
                    digits += 1;
                }
                if (frac) {
                    exp10 -= 1;
                }
            } else if (c != '_') {
                break;
            }
            i += 1;
        }
        if (i < text.len && (text[i] == 'e' || text[i] == 'E')) {
            i += 1;
            var neg = false;
            if (i < text.len && (text[i] == '+' || text[i] == '-')) {
                neg = text[i] == '-';
                i += 1;
            }
            var e: i64 = 0;
            while (i < text.len && text[i] >= '0' && text[i] <= '9') {
                if (e < 1000000) {
                    e = e * 10 + @cast<i64>(text[i] - '0');
                }
                i += 1;
            }
            if (neg) {
                e = -e;
            }
            exp10 += e;
        }
        // a tail that isn't 0: one more digit 1 is as good for rounding
        if (sticky) {
            big_mul_add(&num, 10, 1);
            digits += 1;
            exp10 -= 1;
        }
        while (num.len > 0 && *num.at(num.len - 1) == 0) {
            num.truncate(num.len - 1);
        }
        if (num.len == 0) {
            return 0;
        }
        // past either end, without the arithmetic: 10^4933 is over the largest binary128, and
        // 10^-4967 under half the smallest
        if (exp10 + digits > 4933) {
            return Q_INF;
        }
        if (exp10 + digits < -4967) {
            return 0;
        }
        var den: std::vec<u32> = {};
        den.push(1) catch @panic("out of memory");
        var k: i64 = 0;
        while (k < exp10) {
            big_mul_add(&num, 10, 0);
            k += 1;
        }
        while (k > exp10) {
            big_mul_add(&den, 10, 0);
            k -= 1;
        }
        // num * 2^s / den in [2^115, 2^117)
        val s = 116 - (big_bits(&num) - big_bits(&den));
        var n = copy num;
        var d = copy den;
        if (s >= 0) {
            n = big_shl(&num, s);
        } else {
            d = big_shl(&den, -s);
        }
        var q: u128 = 0;
        var dd = big_shl(&d, 116);
        for (b) in 0..117 {
            q <<= 1;
            if (big_cmp(&n, &dd) >= 0) {
                big_sub(&n, &dd);
                q |= 1;
            }
            big_shr1(&dd);
        }
        var e2 = -s;
        var sticky = n.len > 0;
        if (q >= (@cast<u128>(1) << 116)) {
            sticky = sticky || (q & 1) != 0;
            q >>= 1;
            e2 += 1;
        }
        if (sticky) {
            q |= 1;
        }
        // q * 2^e2, its leading 1 at bit 115: pack128's sig * 2^(exp - 16383 - 115)
        return pack128(0, e2 + 115 + 16383, q);
    }

    // compiler-rt's quad routines (what LLVM calls for f128 arithmetic, compares and conversions) on
    // targets with no C runtime that has them: Apple's arm64 one (its long double is an f64) and
    // os=none (bare metal and WebAssembly: no C runtime at all). Elsewhere libgcc or compiler-rt has
    // them. Item @cfg is AND-only, so each gets a namespace with the same list (tests/golden.rs
    // quad_exports checks they match), the bodies these helpers
    namespace quad_rt {
        public fn b(v: f128) -> u128 { return @bitcast<u128>(v); }
        public fn q(v: u128) -> f128 { return @bitcast<f128>(v); }

        // as libgcc's: <0, 0 or >0 like x - y; a NaN gives 1 to eq/ne/lt/le, -1 to ge/gt
        public fn le(x: f128, y: f128) -> i32 {
            val c = cmp128(b(x), b(y));
            if (c == 2) {
                return 1;
            }
            return c;
        }
        public fn ge(x: f128, y: f128) -> i32 {
            val c = cmp128(b(x), b(y));
            if (c == 2) {
                return -1;
            }
            return c;
        }
        public fn unord(x: f128, y: f128) -> i32 {
            if (is_nan128(b(x)) || is_nan128(b(y))) {
                return 1;
            }
            return 0;
        }

        @attributes([@cfg("os", "macos"), @cfg("arch", "aarch64")])
        namespace apple {
            export fn __addtf3(x: f128, y: f128) -> f128 { return q(add128(b(x), b(y))); }
            export fn __subtf3(x: f128, y: f128) -> f128 { return q(sub128(b(x), b(y))); }
            export fn __multf3(x: f128, y: f128) -> f128 { return q(mul128(b(x), b(y))); }
            export fn __divtf3(x: f128, y: f128) -> f128 { return q(div128(b(x), b(y))); }
            export fn __negtf2(x: f128) -> f128 { return q(b(x) ^ ~Q_ABS); }
            export fn __eqtf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __netf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __lttf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __letf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __getf2(x: f128, y: f128) -> i32 { return ge(x, y); }
            export fn __gttf2(x: f128, y: f128) -> i32 { return ge(x, y); }
            export fn __unordtf2(x: f128, y: f128) -> i32 { return unord(x, y); }
            export fn __extendhftf2(x: f16) -> f128 { return q(f16_to_f128(@bitcast<u16>(x))); }
            export fn __extendsftf2(x: f32) -> f128 { return q(f32_to_f128(@bitcast<u32>(x))); }
            export fn __extenddftf2(x: f64) -> f128 { return q(f64_to_f128(@bitcast<u64>(x))); }
            export fn __trunctfhf2(x: f128) -> f16 { return @bitcast<f16>(f128_to_f16(b(x))); }
            export fn __trunctfsf2(x: f128) -> f32 { return @bitcast<f32>(f128_to_f32(b(x))); }
            export fn __trunctfdf2(x: f128) -> f64 { return @bitcast<f64>(f128_to_f64(b(x))); }
            export fn __fixtfsi(x: f128) -> i32 { return @cast<i32>(f128_to_signed(b(x), 32)); }
            export fn __fixtfdi(x: f128) -> i64 { return @cast<i64>(f128_to_signed(b(x), 64)); }
            export fn __fixtfti(x: f128) -> i128 { return f128_to_signed(b(x), 128); }
            export fn __fixunstfsi(x: f128) -> u32 { return @cast<u32>(f128_to_unsigned(b(x), 32)); }
            export fn __fixunstfdi(x: f128) -> u64 { return @cast<u64>(f128_to_unsigned(b(x), 64)); }
            export fn __fixunstfti(x: f128) -> u128 { return f128_to_unsigned(b(x), 128); }
            export fn __floatsitf(i: i32) -> f128 { return q(i128_to_f128(@cast<i128>(i))); }
            export fn __floatditf(i: i64) -> f128 { return q(i128_to_f128(@cast<i128>(i))); }
            export fn __floattitf(i: i128) -> f128 { return q(i128_to_f128(i)); }
            export fn __floatunsitf(i: u32) -> f128 { return q(u128_to_f128(false, @cast<u128>(i))); }
            export fn __floatunditf(i: u64) -> f128 { return q(u128_to_f128(false, @cast<u128>(i))); }
            export fn __floatuntitf(i: u128) -> f128 { return q(u128_to_f128(false, i)); }
        }

        // the same list as apple's
        @attributes([@cfg("os", "none")])
        namespace bare {
            export fn __addtf3(x: f128, y: f128) -> f128 { return q(add128(b(x), b(y))); }
            export fn __subtf3(x: f128, y: f128) -> f128 { return q(sub128(b(x), b(y))); }
            export fn __multf3(x: f128, y: f128) -> f128 { return q(mul128(b(x), b(y))); }
            export fn __divtf3(x: f128, y: f128) -> f128 { return q(div128(b(x), b(y))); }
            export fn __negtf2(x: f128) -> f128 { return q(b(x) ^ ~Q_ABS); }
            export fn __eqtf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __netf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __lttf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __letf2(x: f128, y: f128) -> i32 { return le(x, y); }
            export fn __getf2(x: f128, y: f128) -> i32 { return ge(x, y); }
            export fn __gttf2(x: f128, y: f128) -> i32 { return ge(x, y); }
            export fn __unordtf2(x: f128, y: f128) -> i32 { return unord(x, y); }
            export fn __extendhftf2(x: f16) -> f128 { return q(f16_to_f128(@bitcast<u16>(x))); }
            export fn __extendsftf2(x: f32) -> f128 { return q(f32_to_f128(@bitcast<u32>(x))); }
            export fn __extenddftf2(x: f64) -> f128 { return q(f64_to_f128(@bitcast<u64>(x))); }
            export fn __trunctfhf2(x: f128) -> f16 { return @bitcast<f16>(f128_to_f16(b(x))); }
            export fn __trunctfsf2(x: f128) -> f32 { return @bitcast<f32>(f128_to_f32(b(x))); }
            export fn __trunctfdf2(x: f128) -> f64 { return @bitcast<f64>(f128_to_f64(b(x))); }
            export fn __fixtfsi(x: f128) -> i32 { return @cast<i32>(f128_to_signed(b(x), 32)); }
            export fn __fixtfdi(x: f128) -> i64 { return @cast<i64>(f128_to_signed(b(x), 64)); }
            export fn __fixtfti(x: f128) -> i128 { return f128_to_signed(b(x), 128); }
            export fn __fixunstfsi(x: f128) -> u32 { return @cast<u32>(f128_to_unsigned(b(x), 32)); }
            export fn __fixunstfdi(x: f128) -> u64 { return @cast<u64>(f128_to_unsigned(b(x), 64)); }
            export fn __fixunstfti(x: f128) -> u128 { return f128_to_unsigned(b(x), 128); }
            export fn __floatsitf(i: i32) -> f128 { return q(i128_to_f128(@cast<i128>(i))); }
            export fn __floatditf(i: i64) -> f128 { return q(i128_to_f128(@cast<i128>(i))); }
            export fn __floattitf(i: i128) -> f128 { return q(i128_to_f128(i)); }
            export fn __floatunsitf(i: u32) -> f128 { return q(u128_to_f128(false, @cast<u128>(i))); }
            export fn __floatunditf(i: u64) -> f128 { return q(u128_to_f128(false, @cast<u128>(i))); }
            export fn __floatuntitf(i: u128) -> f128 { return q(u128_to_f128(false, i)); }
        }
    }
}
