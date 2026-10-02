// std::math::portable: std::math's functions in Volt, the same bits on every machine and no C math
// library needed. Programs with no OS (voltc --target) get them as std::math's; elsewhere std::math
// is the system's libm, and these are here by name. sqrt, floor, ceil, round, trunc and fmod are
// exact; the rest are within an ulp of the true value. Each f32 function computes in f64 and rounds
// once.
//
// Ported from musl's src/math (MIT license, Copyright 2005-2020 Rich Felker, et al.:
// https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT), partly by way of Zig's ports of it. Most of it
// is FreeBSD's msun and Sun's fdlibm, under this notice:
//     Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//     Developed at SunPro, a Sun Microsystems, Inc. business.
//     Permission to use, copy, modify, and distribute this software is freely granted, provided
//     that this notice is preserved.
// exp and pow, and their tables, are Arm's optimized routines (Copyright (c) 2018, Arm Limited,
// MIT license). sqrt is a digit-by-digit square root written for Volt.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace math {
    namespace portable {
        // ---------- bits ----------

        // the bits of an f64
        internal fn bits(v: f64) -> u64 {
            return @bitcast<u64>(v);
        }

        // the f64 with these bits
        internal fn from_bits(b: u64) -> f64 {
            return @bitcast<f64>(b);
        }

        // the high 32 bits: sign, exponent and the fraction's top 20
        internal fn high(x: f64) -> u32 {
            return @cast<u32>(bits(x) >> 32);
        }

        // x * 2^n, rounded once
        internal fn scalbn(x: f64, n0: i32) -> f64 {
            var y = x;
            var n = n0;
            if (n > 1023) {
                y *= 8.98846567431158e+307; // 2^1023
                n -= 1023;
                if (n > 1023) {
                    y *= 8.98846567431158e+307;
                    n -= 1023;
                    if (n > 1023) {
                        n = 1023;
                    }
                }
            } else if (n < -1022) {
                // to below -1022 + 53 first, so the subnormal result rounds only once
                y *= 2.2250738585072014e-308 * 9007199254740992.0; // 2^-1022 * 2^53
                n += 1022 - 53;
                if (n < -1022) {
                    y *= 2.2250738585072014e-308 * 9007199254740992.0;
                    n += 1022 - 53;
                    if (n < -1022) {
                        n = -1022;
                    }
                }
            }
            return y * from_bits(@cast<u64>(0x3FF + n) << 52);
        }

        // ---------- rounding ----------

        // x without its fraction (toward zero)
        fn trunc(x: f64) -> f64 {
            val b = bits(x);
            val e = @cast<i32>((b >> 52) & 0x7FF) - 1023;
            if (e >= 52) {
                return x; // whole already, or infinite, or NaN
            }
            if (e < 0) {
                return from_bits(b & 0x8000000000000000);
            }
            val mask = (@cast<u64>(1) << @cast<u64>(52 - e)) - 1;
            return from_bits(b & ~mask);
        }

        // the largest whole number not above x
        fn floor(x: f64) -> f64 {
            val b = bits(x);
            val e = @cast<i32>((b >> 52) & 0x7FF) - 1023;
            if (e >= 52) {
                return x;
            }
            val neg = (b >> 63) != 0;
            if (e < 0) {
                if ((b << 1) == 0) {
                    return x;
                }
                if (neg) {
                    return -1.0;
                }
                return 0.0;
            }
            val mask = (@cast<u64>(1) << @cast<u64>(52 - e)) - 1;
            if ((b & mask) == 0) {
                return x;
            }
            if (neg) {
                return from_bits((b + mask + 1) & ~mask); // one more in magnitude
            }
            return from_bits(b & ~mask);
        }

        // the smallest whole number not below x
        fn ceil(x: f64) -> f64 {
            val b = bits(x);
            val e = @cast<i32>((b >> 52) & 0x7FF) - 1023;
            if (e >= 52) {
                return x;
            }
            val neg = (b >> 63) != 0;
            if (e < 0) {
                if ((b << 1) == 0) {
                    return x;
                }
                if (neg) {
                    return -0.0;
                }
                return 1.0;
            }
            val mask = (@cast<u64>(1) << @cast<u64>(52 - e)) - 1;
            if ((b & mask) == 0) {
                return x;
            }
            if (!neg) {
                return from_bits((b + mask + 1) & ~mask);
            }
            return from_bits(b & ~mask);
        }

        // the nearest whole number, halves away from zero
        fn round(x: f64) -> f64 {
            val b = bits(x);
            val e = @cast<i32>((b >> 52) & 0x7FF) - 1023;
            if (e >= 52) {
                return x;
            }
            if (e < -1) {
                return from_bits(b & 0x8000000000000000); // under a half
            }
            if (e == -1) {
                return from_bits((b & 0x8000000000000000) | 0x3FF0000000000000); // a half to 1: one
            }
            val mask = (@cast<u64>(1) << @cast<u64>(52 - e)) - 1;
            if ((b & mask) == 0) {
                return x;
            }
            val half = @cast<u64>(1) << @cast<u64>(51 - e);
            return from_bits((b + half) & ~mask);
        }

        // the remainder of x / y, with x's sign: exact (musl's fmod)
        fn fmod(x: f64, y: f64) -> f64 {
            var ux = bits(x);
            var uy = bits(y);
            var ex = @cast<i32>((ux >> 52) & 0x7FF);
            var ey = @cast<i32>((uy >> 52) & 0x7FF);
            val sx = ux >> 63;
            if ((uy << 1) == 0 || y != y || ex == 0x7FF) {
                return (x * y) / (x * y);
            }
            if ((ux << 1) <= (uy << 1)) {
                if ((ux << 1) == (uy << 1)) {
                    return 0.0 * x;
                }
                return x;
            }
            // both as integers with the leading 1 at bit 52
            if (ex == 0) {
                var i = ux << 12;
                while ((i >> 63) == 0) {
                    ex -= 1;
                    i <<= 1;
                }
                ux <<= @cast<u64>(1 - ex);
            } else {
                ux &= 0x000FFFFFFFFFFFFF;
                ux |= @cast<u64>(1) << 52;
            }
            if (ey == 0) {
                var i = uy << 12;
                while ((i >> 63) == 0) {
                    ey -= 1;
                    i <<= 1;
                }
                uy <<= @cast<u64>(1 - ey);
            } else {
                uy &= 0x000FFFFFFFFFFFFF;
                uy |= @cast<u64>(1) << 52;
            }
            // long division, a bit at a time
            while (ex > ey) {
                val i = ux -% uy;
                if ((i >> 63) == 0) {
                    if (i == 0) {
                        return 0.0 * x;
                    }
                    ux = i;
                }
                ux <<= 1;
                ex -= 1;
            }
            val i = ux -% uy;
            if ((i >> 63) == 0) {
                if (i == 0) {
                    return 0.0 * x;
                }
                ux = i;
            }
            while ((ux >> 52) == 0) {
                ux <<= 1;
                ex -= 1;
            }
            if (ex > 0) {
                ux -= @cast<u64>(1) << 52;
                ux |= @cast<u64>(ex) << 52;
            } else {
                ux >>= @cast<u64>(1 - ex);
            }
            return from_bits(ux | (sx << 63));
        }

        // ---------- roots ----------

        // the square root, correctly rounded: digit by digit on the significand, two bits a step
        fn sqrt(x: f64) -> f64 {
            val b = bits(x);
            if (b == 0x7FF0000000000000 || (b << 1) == 0) {
                return x; // +inf, +-0
            }
            if ((b >> 63) != 0 || (b >> 52) == 0x7FF) {
                if (x != x) {
                    return x;
                }
                return (x - x) / (x - x); // below zero: NaN
            }
            // x = m * 2^e, m a whole number with its leading 1 at bit 52, e even
            var e = @cast<i32>(b >> 52);
            var m = b & 0x000FFFFFFFFFFFFF;
            if (e == 0) {
                while ((m & (@cast<u64>(1) << 52)) == 0) {
                    m <<= 1;
                    e -= 1;
                }
                e += 1;
            } else {
                m |= @cast<u64>(1) << 52;
            }
            e -= 1075;
            if ((e & 1) != 0) {
                m <<= 1;
                e -= 1;
            }
            // q = floor(sqrt(m * 2^54)), 54 bits; r what's left over
            var q: u64 = 0;
            var r: u64 = 0;
            for (i) in 0..54 {
                var pair: u64 = 0;
                if (i < 27) {
                    pair = (m >> @cast<u64>(52 - 2 * i)) & 3;
                }
                r = (r << 2) | pair;
                val t = (q << 2) | 1;
                q <<= 1;
                if (r >= t) {
                    r -= t;
                    q |= 1;
                }
            }
            // q's last bit is the half; a root is never exactly halfway
            var mant = (q >> 1) + (q & 1);
            var ex = e / 2 + 1049;
            if (mant == (@cast<u64>(1) << 53)) {
                mant >>= 1;
                ex += 1;
            }
            return from_bits((@cast<u64>(ex) << 52) | (mant & 0x000FFFFFFFFFFFFF));
        }

        // the cube root (musl's cbrt)
        fn cbrt(x: f64) -> f64 {
            val B1: u32 = 715094163; // (1023 - 1023/3 - 0.03306235651) * 2^20
            val B2: u32 = 696219795; // (1023 - 1023/3 - 54/3 - 0.03306235651) * 2^20
            val P0 = 1.87595182427177009643;
            val P1 = -1.88497979543377169875;
            val P2 = 1.621429720105354466140;
            val P3 = -0.758397934778766047437;
            val P4 = 0.145996192886612446982;
            var u = bits(x);
            var hx = @cast<u32>(u >> 32) & 0x7FFFFFFF;
            if (hx >= 0x7FF00000) {
                return x + x; // NaN, infinity
            }
            // the cube root to 5 bits, from the exponent
            if (hx < 0x00100000) {
                u = bits(x * 18014398509481984.0); // 2^54
                hx = @cast<u32>(u >> 32) & 0x7FFFFFFF;
                if (hx == 0) {
                    return x; // +-0
                }
                hx = hx / 3 + B2;
            } else {
                hx = hx / 3 + B1;
            }
            u &= @cast<u64>(1) << 63;
            u |= @cast<u64>(hx) << 32;
            var t = from_bits(u);
            // to 23 bits: cbrt(x) = t * cbrt(x / t^3) ~= t * P(t^3 / x)
            val r = (t * t) * (t / x);
            t = t * ((P0 + r * (P1 + r * P2)) + ((r * r) * r) * (P3 + r * P4));
            // rounded away from 0 to 23 bits, then one Newton step to 53
            t = from_bits((bits(t) + 0x80000000) & 0xFFFFFFFFC0000000);
            val s = t * t;
            var q = x / s;
            val w = t + t;
            q = (q - t) / (w + q);
            return t + t * q;
        }

        // the length of the hypotenuse, sqrt(x*x + y*y) without overflowing (musl's hypot: the squares
        // split into exact halves)
        fn hypot(x0: f64, y0: f64) -> f64 {
            var ux = bits(x0) & 0x7FFFFFFFFFFFFFFF;
            var uy = bits(y0) & 0x7FFFFFFFFFFFFFFF;
            if (ux < uy) {
                val t = ux;
                ux = uy;
                uy = t;
            }
            val ex = @cast<i32>(ux >> 52);
            val ey = @cast<i32>(uy >> 52);
            var x = from_bits(ux);
            var y = from_bits(uy);
            if (ey == 0x7FF) {
                return y; // hypot(inf, nan) is inf
            }
            if (ex == 0x7FF || uy == 0) {
                return x;
            }
            if (ex - ey > 64) {
                return x + y;
            }
            // scaled so the squares neither overflow nor lose their low halves
            var z = 1.0;
            if (ex > 0x3FF + 510) {
                z = 5.260135901548374e+210; // 2^700
                x *= 1.90109156629516e-211;
                y *= 1.90109156629516e-211;
            } else if (ey < 0x3FF - 450) {
                z = 1.90109156629516e-211;
                x *= 5.260135901548374e+210;
                y *= 5.260135901548374e+210;
            }
            var hx = 0.0;
            var lx = 0.0;
            var hy = 0.0;
            var ly = 0.0;
            square(x, &hx, &lx);
            square(y, &hy, &ly);
            return z * sqrt(ly + lx + hy + hx);
        }

        // x*x as hi + lo exactly (Dekker's split)
        internal fn square(x: f64, hi: f64&, lo: f64&) -> void {
            val xc = x * 134217729.0; // 2^27 + 1
            val xh = x - xc + xc;
            val xl = x - xh;
            *hi = x * x;
            *lo = xh * xh - *hi + 2.0 * xh * xl + xl * xl;
        }

        // ---------- exponentials ----------

        // when pow or exp overflows: infinity with a sign
        internal fn overflow(neg: bool) -> f64 {
            val y = 3.105036184601418e+231; // 2^769
            if (neg) {
                return -y * y;
            }
            return y * y;
        }

        // when it underflows: zero with a sign
        internal fn underflow(neg: bool) -> f64 {
            val y = 1.2882297539194267e-231; // 2^-767
            if (neg) {
                return -y * y;
            }
            return y * y;
        }

        // the top 12 bits: sign and exponent
        internal fn top12(x: f64) -> u32 {
            return @cast<u32>(bits(x) >> 52);
        }

        // scale * (1 + tmp) where scale's exponent (in sbits) may have overflowed or underflowed: k
        // (the low 32 bits of ki) says which
        internal fn exp_special(tmp: f64, sbits0: u64, ki: u64) -> f64 {
            var sbits = sbits0;
            if ((ki & 0x80000000) == 0) {
                // k > 0: the exponent may be up to 460 too big
                sbits -%= @cast<u64>(1009) << 52; // (wrapping: it may have carried into the sign)
                val scale = from_bits(sbits);
                return 5.486124068793689e+303 * (scale + scale * tmp); // 2^1009
            }
            // k < 0: in the subnormal range, round once
            sbits = sbits +% (@cast<u64>(1022) << 52);
            val scale = from_bits(sbits);
            var y = scale + scale * tmp;
            if (y < 1.0 && y > -1.0) {
                var one = 1.0;
                if (y < 0.0) {
                    one = -1.0;
                }
                var lo = scale - y + scale * tmp;
                val hi = one + y;
                lo = one - hi + y + lo;
                y = (hi + lo) - one;
                if (y == 0.0) {
                    y = from_bits(sbits & 0x8000000000000000);
                }
            }
            return 2.2250738585072014e-308 * y; // 2^-1022
        }

        // exp(x + xtail), negated when neg; |xtail| < 2^-15 and |xtail| <= |x| (musl's, from Arm's
        // optimized routines: 2^(k/128) from a table, then a polynomial for what's left)
        internal fn exp_inline(x: f64, xtail: f64, neg: bool) -> f64 {
            var abstop = top12(x) & 0x7FF;
            // 0x3C9 is top12(2^-54), 0x408 top12(512)
            if (abstop -% 0x3C9 >= 0x408 - 0x3C9) {
                if (abstop -% 0x3C9 >= 0x80000000) {
                    // tiny x
                    if (neg) {
                        return -(1.0 + x);
                    }
                    return 1.0 + x;
                }
                if (abstop >= 0x409) {
                    // |x| >= 1024 (infinity and NaN are handled before)
                    if ((bits(x) >> 63) != 0) {
                        return underflow(neg);
                    }
                    return overflow(neg);
                }
                abstop = 0; // large: done carefully below
            }
            // x = k ln2/128 + r, r in [-ln2/256, ln2/256]
            val z = 184.6649652337873 * x; // 128/ln2
            var kd = z + 6755399441055744.0; // 1.5 * 2^52: rounds to a whole number
            val ki = bits(kd);
            kd -= 6755399441055744.0;
            var r = x + kd * -0.005415212348111709 + kd * -1.2864023111638346e-14; // -ln2/128, hi and lo
            r += xtail;
            // 2^(k/128) ~= scale * (1 + tail)
            val idx = @cast<usize>(2 * (ki % 128));
            var top = ki << 45;
            if (neg) {
                top = top +% (@cast<u64>(0x40000) << 45); // the sign, through the exponent's carry
            }
            val tail = from_bits(EXP_TAB[idx]);
            val sbits = EXP_TAB[idx + 1] +% top;
            val r2 = r * r;
            val tmp = tail + r + r2 * (0.49999999999996786 + r * 0.16666666666665886) + r2 * r2 * (0.0416666808410674 + r * 0.008333335853059549);
            if (abstop == 0) {
                return exp_special(tmp, sbits, ki);
            }
            val scale = from_bits(sbits);
            return scale + scale * tmp;
        }

        // e^x
        fn exp(x: f64) -> f64 {
            val abstop = top12(x) & 0x7FF;
            if (abstop >= 0x409) {
                if (bits(x) == 0xFFF0000000000000) {
                    return 0.0; // e^-inf
                }
                if (abstop >= 0x7FF) {
                    return 1.0 + x; // inf, NaN
                }
            }
            return exp_inline(x, 0.0, false);
        }

        // 2^x (musl's older exp2: a 256-entry table and a polynomial)
        fn exp2(x: f64) -> f64 {
            val ux = bits(x);
            val ix = @cast<u32>(ux >> 32) & 0x7FFFFFFF;
            if (x != x) {
                return x;
            }
            if (ix >= 0x408FF000) {
                // |x| >= 1022
                if (ix >= 0x40900000 && (ux >> 63) == 0) {
                    return x * 8.98846567431158e+307; // x >= 1024: overflow
                }
                if (ix >= 0x7FF00000) {
                    return -1.0 / x; // -inf: 0
                }
                if ((ux >> 63) != 0 && x <= -1075.0) {
                    return 0.0;
                }
            } else if (ix < 0x3C900000) {
                return 1.0 + x; // |x| < 2^-54
            }
            // x = k/256 + i/256 + z: the table gives 2^(i/256), the polynomial 2^z
            val redux = 26388279066624.0; // 1.5 * 2^52 / 256
            var uf = x + redux;
            var i0 = @cast<u32>(bits(uf) & 0xFFFFFFFF) +% 128;
            // k: i0 rounded down to a multiple of 256, read as a signed 32-bit number, over 256
            var k = @cast<i64>(i0 / 256 * 256);
            if (k >= 0x80000000) {
                k -= 0x100000000;
            }
            val ik = @cast<i32>(k / 256);
            i0 %= 256;
            uf -= redux;
            var z = x - uf;
            val t = EXP2_TAB[@cast<usize>(2 * i0)];
            z -= EXP2_TAB[@cast<usize>(2 * i0 + 1)];
            val r = t + t * z * (0.6931471805599453 + z * (0.2402265069591 + z * (0.0555041086648214 + z * (0.009618129842126066 + z * 0.0013333559164630223))));
            return scalbn(r, ik);
        }

        // e^x - 1, exact near 0 (musl's expm1)
        fn expm1(x0: f64) -> f64 {
            val o_threshold = 709.782712893383973096;
            val ln2_hi = 6.93147180369123816490e-01;
            val ln2_lo = 1.90821492927058770002e-10;
            val invln2 = 1.44269504088896338700e+00;
            val Q1 = -3.33333333333331316428e-02;
            val Q2 = 1.58730158725481460165e-03;
            val Q3 = -7.93650757867487942473e-05;
            val Q4 = 4.00821782732936239552e-06;
            val Q5 = -2.01099218183624371326e-07;
            var x = x0;
            val ux = bits(x);
            val hx = @cast<u32>(ux >> 32) & 0x7FFFFFFF;
            val sign = (ux >> 63) != 0;
            if (hx >= 0x4043687A) {
                // |x| >= 56 ln2
                if (x != x) {
                    return x;
                }
                if (sign) {
                    return -1.0;
                }
                if (x > o_threshold) {
                    return x * 8.98846567431158e+307; // overflow
                }
            }
            var hi = 0.0;
            var lo = 0.0;
            var c = 0.0;
            var k: i32 = 0;
            if (hx > 0x3FD62E42) {
                // |x| > ln2 / 2
                if (hx < 0x3FF0A2B2) {
                    // and < 1.5 ln2
                    if (!sign) {
                        hi = x - ln2_hi;
                        lo = ln2_lo;
                        k = 1;
                    } else {
                        hi = x + ln2_hi;
                        lo = -ln2_lo;
                        k = -1;
                    }
                } else {
                    var kf = invln2 * x;
                    if (sign) {
                        kf -= 0.5;
                    } else {
                        kf += 0.5;
                    }
                    k = @cast<i32>(kf);
                    val t = @cast<f64>(k);
                    hi = x - t * ln2_hi;
                    lo = t * ln2_lo;
                }
                x = hi - lo;
                c = (hi - x) - lo;
            } else if (hx < 0x3C900000) {
                return x; // |x| < 2^-54
            }
            val hfx = 0.5 * x;
            val hxs = x * hfx;
            val r1 = 1.0 + hxs * (Q1 + hxs * (Q2 + hxs * (Q3 + hxs * (Q4 + hxs * Q5))));
            val t = 3.0 - r1 * hfx;
            var e = hxs * ((r1 - t) / (6.0 - x * t));
            if (k == 0) {
                return x - (x * e - hxs);
            }
            e = x * (e - c) - c;
            e -= hxs;
            if (k == -1) {
                return 0.5 * (x - e) - 0.5;
            }
            if (k == 1) {
                if (x < -0.25) {
                    return -2.0 * (e - (x + 0.5));
                }
                return 1.0 + 2.0 * (x - e);
            }
            val twopk = from_bits(@cast<u64>(0x3FF + k) << 52);
            if (k < 0 || k > 56) {
                var y = x - e + 1.0;
                if (k == 1024) {
                    y = y * 2.0 * 8.98846567431158e+307;
                } else {
                    y = y * twopk;
                }
                return y - 1.0;
            }
            val uf = from_bits(@cast<u64>(0x3FF - k) << 52);
            if (k < 20) {
                return (x - e + (1.0 - uf)) * twopk;
            }
            return (x - (e + uf) + 1.0) * twopk;
        }

        // e^x * 2^-1021 * 2^1021, for x past where e^x overflows on its own
        internal fn expo2(x: f64) -> f64 {
            val scale = from_bits(@cast<u64>(0x3FF + 1021) << 52);
            return exp(x - 1416.0996898839683) * scale * scale; // 2043 ln2
        }

        // ---------- logarithms ----------

        // x = 2^k (1 + f), 1 + f in [sqrt(2)/2, sqrt(2)), for log, log2 and log10, which handle 0,
        // negatives, infinity, NaN and 1 first
        internal fn log_reduce(x0: f64, k: i32&) -> f64 {
            var x = x0;
            var ix = bits(x);
            var hx = @cast<u32>(ix >> 32);
            *k = 0;
            if (hx < 0x00100000) {
                // subnormal: scaled up
                *k -= 54;
                x *= 18014398509481984.0;
                ix = bits(x);
                hx = @cast<u32>(ix >> 32);
            }
            hx += 0x3FF00000 - 0x3FE6A09E;
            *k += @cast<i32>(hx >> 20) - 0x3FF;
            hx = (hx & 0x000FFFFF) + 0x3FE6A09E;
            ix = (@cast<u64>(hx) << 32) | (ix & 0xFFFFFFFF);
            return from_bits(ix) - 1.0;
        }

        // log's answer for 0, negatives, infinity, NaN and 1; null for the rest
        internal fn log_special(x: f64) -> f64? {
            val ix = bits(x);
            if ((ix << 1) == 0) {
                return -1.0 / (x * x); // -inf
            }
            if ((ix >> 63) != 0) {
                return (x - x) / 0.0; // NaN
            }
            if ((ix >> 52) >= 0x7FF) {
                return x;
            }
            if (ix == 0x3FF0000000000000) {
                return 0.0;
            }
            return null;
        }

        internal val LG1 = 6.666666666666735130e-01;
        internal val LG2 = 3.999999999940941908e-01;
        internal val LG3 = 2.857142874366239149e-01;
        internal val LG4 = 2.222219843214978396e-01;
        internal val LG5 = 1.818357216161805012e-01;
        internal val LG6 = 1.531383769920937332e-01;
        internal val LG7 = 1.479819860511658591e-01;

        // the natural logarithm (fdlibm's)
        fn log(x: f64) -> f64 {
            val sp = log_special(x);
            if (sp) {
                return sp;
            }
            var k: i32 = 0;
            val f = log_reduce(x, &k);
            val hfsq = 0.5 * f * f;
            val s = f / (2.0 + f);
            val z = s * s;
            val w = z * z;
            val t1 = w * (LG2 + w * (LG4 + w * LG6));
            val t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
            val R = t2 + t1;
            val dk = @cast<f64>(k);
            return s * (hfsq + R) + dk * 1.90821492927058770002e-10 - hfsq + f + dk * 6.93147180369123816490e-01;
        }

        // log(1 + f) as hi + lo, hi with 32 bits so products with it are exact
        internal fn log1p_split(f: f64, lo: f64&) -> f64 {
            val hfsq = 0.5 * f * f;
            val s = f / (2.0 + f);
            val z = s * s;
            val w = z * z;
            val t1 = w * (LG2 + w * (LG4 + w * LG6));
            val t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
            val R = t2 + t1;
            val hi = from_bits(bits(f - hfsq) & 0xFFFFFFFF00000000);
            *lo = f - hi - hfsq + s * (hfsq + R);
            return hi;
        }

        // the base-2 logarithm (fdlibm's)
        fn log2(x: f64) -> f64 {
            val sp = log_special(x);
            if (sp) {
                return sp;
            }
            var k: i32 = 0;
            val f = log_reduce(x, &k);
            var lo = 0.0;
            val hi = log1p_split(f, &lo);
            val ivln2hi = 1.44269504072144627571e+00;
            val ivln2lo = 1.67517131648865118353e-10;
            var val_hi = hi * ivln2hi;
            var val_lo = (lo + hi) * ivln2lo + lo * ivln2hi;
            val y = @cast<f64>(k);
            val ww = y + val_hi;
            val_lo += (y - ww) + val_hi;
            val_hi = ww;
            return val_lo + val_hi;
        }

        // the base-10 logarithm (fdlibm's)
        fn log10(x: f64) -> f64 {
            val sp = log_special(x);
            if (sp) {
                return sp;
            }
            var k: i32 = 0;
            val f = log_reduce(x, &k);
            var lo = 0.0;
            val hi = log1p_split(f, &lo);
            val ivln10hi = 4.34294481878168880939e-01;
            val ivln10lo = 2.50829467116452752298e-11;
            val log10_2hi = 3.01029995663611771306e-01;
            val log10_2lo = 3.69423907715893078616e-13;
            var val_hi = hi * ivln10hi;
            val dk = @cast<f64>(k);
            val y = dk * log10_2hi;
            var val_lo = dk * log10_2lo + (lo + hi) * ivln10lo + lo * ivln10hi;
            val ww = y + val_hi;
            val_lo += (y - ww) + val_hi;
            val_hi = ww;
            return val_lo + val_hi;
        }

        // ---------- pow ----------

        // log(x) as hi + *tail with about 15 more bits, for pow; ix is x's bits with a subnormal
        // normalised (its exponent then negative)
        internal fn pow_log(ix: u64, tail: f64&) -> f64 {
            // x = 2^k z, z in [0x3FE6955500000000, twice that), in one of 128 intervals with c near
            // its middle
            val tmp = ix -% 0x3FE6955500000000;
            val i = @cast<usize>((tmp >> 45) % 128);
            val k = @cast<i64>(tmp) >> 52;
            val iz = ix -% (tmp & (@cast<u64>(0xFFF) << 52));
            val z = from_bits(iz);
            val kd = @cast<f64>(k);
            // log(x) = k ln2 + log(c) + log1p(z/c - 1)
            val invc = POW_LOG_TAB[3 * i];
            val logc = POW_LOG_TAB[3 * i + 1];
            val logctail = POW_LOG_TAB[3 * i + 2];
            // z split so rhi, rlo and rhi * rhi are exact
            val zhi = from_bits((iz +% (@cast<u64>(1) << 31)) & 0xFFFFFFFF00000000);
            val zlo = z - zhi;
            val rhi = zhi * invc - 1.0;
            val rlo = zlo * invc;
            val r = rhi + rlo;
            val t1 = kd * 0.6931471805598903 + logc; // ln2 hi
            val t2 = t1 + r;
            val lo1 = kd * 5.497923018708371e-14 + logctail; // ln2 lo
            val lo2 = t1 - t2 + r;
            val ar = -0.5 * r;
            val ar2 = r * ar;
            val ar3 = r * ar2;
            val arhi = -0.5 * rhi;
            val arhi2 = rhi * arhi;
            val hi = t2 + arhi2;
            val lo3 = rlo * (ar + arhi);
            val lo4 = t2 - hi + arhi2;
            val p = ar3 * (-0.6666666666666679 + r * 0.5000000000000007 + ar2 * (0.7999999995323976 + r * -0.6666666663487739 + ar2 * (-1.142909628459501 + r * 1.0000415263675542)));
            val lo = lo1 + lo2 + lo3 + lo4 + p;
            val y = hi + lo;
            *tail = hi - y + lo;
            return y;
        }

        // 0 when y (bits, finite and not 0) isn't a whole number, 1 when it's odd, 2 when even
        internal fn pow_int_kind(iy: u64) -> i32 {
            val e = @cast<i32>((iy >> 52) & 0x7FF);
            if (e < 0x3FF) {
                return 0;
            }
            if (e > 0x3FF + 52) {
                return 2;
            }
            val unit = @cast<u64>(1) << @cast<u64>(0x3FF + 52 - e);
            if ((iy & (unit - 1)) != 0) {
                return 0;
            }
            if ((iy & unit) != 0) {
                return 1;
            }
            return 2;
        }

        // whether the bits are 0, infinity or NaN
        internal fn zero_inf_nan(i: u64) -> bool {
            return (2 *% i) -% 1 >= 0xFFDFFFFFFFFFFFFF; // 2 * inf's bits - 1
        }

        // x to the power y (musl's pow, from Arm's optimized routines: within 0.52 ulp)
        fn pow(x: f64, y: f64) -> f64 {
            var neg = false;
            var ix = bits(x);
            val iy = bits(y);
            var topx = top12(x);
            val topy = top12(y);
            if (topx -% 0x001 >= 0x7FF - 0x001 || (topy & 0x7FF) -% 0x3BE >= 0x43E - 0x3BE) {
                // x < 2^-1022, infinite or NaN, or |y| < 2^-65, |y| >= 2^63 or NaN
                if (zero_inf_nan(iy)) {
                    if ((iy << 1) == 0) {
                        return 1.0;
                    }
                    if (ix == 0x3FF0000000000000) {
                        return 1.0;
                    }
                    if ((ix << 1) > 0xFFE0000000000000 || (iy << 1) > 0xFFE0000000000000) {
                        return x + y;
                    }
                    if ((ix << 1) == 0x7FE0000000000000) {
                        return 1.0; // (-1)^inf
                    }
                    if (((ix << 1) < 0x7FE0000000000000) == ((iy >> 63) == 0)) {
                        return 0.0; // |x| < 1 and y inf, or |x| > 1 and y -inf
                    }
                    return y * y;
                }
                if (zero_inf_nan(ix)) {
                    var x2 = x * x;
                    if ((ix >> 63) != 0 && pow_int_kind(iy) == 1) {
                        x2 = -x2;
                    }
                    if ((iy >> 63) != 0) {
                        return 1.0 / x2;
                    }
                    return x2;
                }
                // x and y finite, not 0
                if ((ix >> 63) != 0) {
                    val yint = pow_int_kind(iy);
                    if (yint == 0) {
                        return (x - x) / (x - x); // a negative to a fraction: NaN
                    }
                    if (yint == 1) {
                        neg = true;
                    }
                    ix &= 0x7FFFFFFFFFFFFFFF;
                    topx &= 0x7FF;
                }
                if ((topy & 0x7FF) -% 0x3BE >= 0x43E - 0x3BE) {
                    if (ix == 0x3FF0000000000000) {
                        return 1.0;
                    }
                    if ((topy & 0x7FF) < 0x3BE) {
                        // |y| < 2^-65: x^y ~= 1 + y log(x)
                        if (ix > 0x3FF0000000000000) {
                            return 1.0 + y;
                        }
                        return 1.0 - y;
                    }
                    if ((ix > 0x3FF0000000000000) == (topy < 0x800)) {
                        return overflow(false);
                    }
                    return underflow(false);
                }
                if (topx == 0) {
                    // subnormal x: normalised, its exponent below zero
                    ix = bits(x * 4503599627370496.0) & 0x7FFFFFFFFFFFFFFF; // 2^52
                    ix = ix -% (@cast<u64>(52) << 52);
                }
            }
            var lo = 0.0;
            val hi = pow_log(ix, &lo);
            // y * (hi + lo) as ehi + elo, the halves split so ehi is exact
            val yhi = from_bits(iy & 0xFFFFFFFFF8000000);
            val ylo = y - yhi;
            val lhi = from_bits(bits(hi) & 0xFFFFFFFFF8000000);
            val llo = hi - lhi + lo;
            val ehi = yhi * lhi;
            val elo = ylo * lhi + y * llo;
            return exp_inline(ehi, elo, neg);
        }

        // ---------- trigonometry ----------

        // sin(x + y) for |x| <= pi/4, y the tail of x; y is 0 when iy is (fdlibm's __sin)
        internal fn sin_kernel(x: f64, y: f64, iy: i32) -> f64 {
            val S1 = -1.66666666666666324348e-01;
            val S2 = 8.33333333332248946124e-03;
            val S3 = -1.98412698298579493134e-04;
            val S4 = 2.75573137070700676789e-06;
            val S5 = -2.50507602534068634195e-08;
            val S6 = 1.58969099521155010221e-10;
            val z = x * x;
            val w = z * z;
            val r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
            val v = z * x;
            if (iy == 0) {
                return x + v * (S1 + z * r);
            }
            return x - ((z * (0.5 * y - v * r) - y) - v * S1);
        }

        // cos(x + y) for |x| <= pi/4 (fdlibm's __cos)
        internal fn cos_kernel(x: f64, y: f64) -> f64 {
            val C1 = 4.16666666666666019037e-02;
            val C2 = -1.38888888888741095749e-03;
            val C3 = 2.48015872894767294178e-05;
            val C4 = -2.75573143513906633035e-07;
            val C5 = 2.08757232129817482790e-09;
            val C6 = -1.13596475577881948265e-11;
            val z = x * x;
            val zs = z * z;
            val r = z * (C1 + z * (C2 + z * C3)) + zs * zs * (C4 + z * (C5 + z * C6));
            val hz = 0.5 * z;
            val w = 1.0 - hz;
            return w + (((1.0 - w) - hz) + (z * r - x * y));
        }

        internal val TAN_T: f64[13] = {
            3.33333333333334091986e-01, 1.33333333333201242699e-01, 5.39682539762260521377e-02,
            2.18694882948595424599e-02, 8.86323982359930005737e-03, 3.59207910759131235356e-03,
            1.45620945432529025516e-03, 5.88041240820264096874e-04, 2.46463134818469906812e-04,
            7.81794442939557092300e-05, 7.14072491382608190305e-05, -1.85586374855275456654e-05,
            2.59073051863633712884e-05,
        };

        // tan(x + y), or -1/tan(x + y) when odd, for |x| <= pi/4 (fdlibm's __tan)
        internal fn tan_kernel(x0: f64, y0: f64, odd: bool) -> f64 {
            val pio4 = 7.85398163397448278999e-01;
            val pio4lo = 3.06161699786838301793e-17;
            var x = x0;
            var y = y0;
            val hx = high(x);
            val big = (hx & 0x7FFFFFFF) >= 0x3FE59428; // |x| >= 0.6744
            var sign = false;
            if (big) {
                sign = (hx >> 31) != 0;
                if (sign) {
                    x = -x;
                    y = -y;
                }
                x = (pio4 - x) + (pio4lo - y);
                y = 0.0;
            }
            val z = x * x;
            var w = z * z;
            var r = TAN_T[1] + w * (TAN_T[3] + w * (TAN_T[5] + w * (TAN_T[7] + w * (TAN_T[9] + w * TAN_T[11]))));
            var v = z * (TAN_T[2] + w * (TAN_T[4] + w * (TAN_T[6] + w * (TAN_T[8] + w * (TAN_T[10] + w * TAN_T[12])))));
            var s = z * x;
            r = y + z * (s * (r + v) + y) + s * TAN_T[0];
            w = x + r;
            if (big) {
                s = 1.0;
                if (odd) {
                    s = -1.0;
                }
                v = s - 2.0 * (x + (r - w * w / (w + s)));
                if (sign) {
                    return -v;
                }
                return v;
            }
            if (!odd) {
                return w;
            }
            // -1/(x + r), carefully: the plain division has up to 2 ulp of error
            val w0 = from_bits(bits(w) & 0xFFFFFFFF00000000);
            v = r - (w0 - x);
            val a = -1.0 / w;
            val a0 = from_bits(bits(a) & 0xFFFFFFFF00000000);
            return a0 + a * (1.0 + a0 * w0 + a0 * v);
        }

        // x - n pi/2 as *y0 + *y1, for |x| below 2^20 pi/2: n is rint(x / (pi/2)), and pi/2 is taken
        // in up to three 33-bit parts as x's size needs
        internal fn rem_pio2_medium(ix: u32, x: f64, y0: f64&, y1: f64&) -> i32 {
            val invpio2 = 6.36619772367581382433e-01;
            val pio2_1 = 1.57079632673412561417e+00;
            val pio2_1t = 6.07710050650619224932e-11;
            val pio2_2 = 6.07710050630396597660e-11;
            val pio2_2t = 2.02226624879595063154e-21;
            val pio2_3 = 2.02226624871116645580e-21;
            val pio2_3t = 8.47842766036889956997e-32;
            val pio4 = 0.7853981633974483;
            val toint = 6755399441055744.0; // 1.5 * 2^52
            var fn_ = x * invpio2 + toint - toint;
            var n = @cast<i32>(fn_);
            var r = x - fn_ * pio2_1;
            var w = fn_ * pio2_1t;
            // (for rounding modes other than nearest)
            if (r - w < -pio4) {
                n -= 1;
                fn_ -= 1.0;
                r = x - fn_ * pio2_1;
                w = fn_ * pio2_1t;
            } else if (r - w > pio4) {
                n += 1;
                fn_ += 1.0;
                r = x - fn_ * pio2_1;
                w = fn_ * pio2_1t;
            }
            *y0 = r - w;
            var ey = @cast<i32>((bits(*y0) >> 52) & 0x7FF);
            val ex = @cast<i32>(ix >> 20);
            if (ex - ey > 16) {
                // a second round, good to 118 bits
                var t = r;
                w = fn_ * pio2_2;
                r = t - w;
                w = fn_ * pio2_2t - ((t - r) - w);
                *y0 = r - w;
                ey = @cast<i32>((bits(*y0) >> 52) & 0x7FF);
                if (ex - ey > 49) {
                    // a third, good to 151 bits: enough for every f64
                    t = r;
                    w = fn_ * pio2_3;
                    r = t - w;
                    w = fn_ * pio2_3t - ((t - r) - w);
                    *y0 = r - w;
                }
            }
            *y1 = (r - *y0) - w;
            return n;
        }

        // x - n pi/2 as *y0 + *y1, and n (only its low bits matter): fdlibm's __rem_pio2
        internal fn rem_pio2(x: f64, y0: f64&, y1: f64&) -> i32 {
            val pio2_1 = 1.57079632673412561417e+00;
            val pio2_1t = 6.07710050650619224932e-11;
            val ux = bits(x);
            val sign = (ux >> 63) != 0;
            val ix = @cast<u32>(ux >> 32) & 0x7FFFFFFF;
            if (ix <= 0x400F6A7A) {
                // |x| ~<= 5pi/4
                if ((ix & 0xFFFFF) == 0x921FB) {
                    return rem_pio2_medium(ix, x, y0, y1); // near pi/2 or pi: cancellation
                }
                var n: i32 = 1;
                var c = pio2_1;
                var ct = pio2_1t;
                if (ix > 0x4002D97C) {
                    // ~> 3pi/4
                    n = 2;
                    c = 2.0 * pio2_1;
                    ct = 2.0 * pio2_1t;
                }
                if (!sign) {
                    val z = x - c;
                    *y0 = z - ct;
                    *y1 = (z - *y0) - ct;
                    return n;
                }
                val z = x + c;
                *y0 = z + ct;
                *y1 = (z - *y0) + ct;
                return -n;
            }
            if (ix <= 0x401C463B) {
                // |x| ~<= 9pi/4
                var n: i32 = 3;
                if (ix <= 0x4015FDBC) {
                    if (ix == 0x4012D97C) {
                        return rem_pio2_medium(ix, x, y0, y1); // ~3pi/2
                    }
                } else {
                    if (ix == 0x401921FB) {
                        return rem_pio2_medium(ix, x, y0, y1); // ~2pi
                    }
                    n = 4;
                }
                val c = @cast<f64>(n) * pio2_1;
                val ct = @cast<f64>(n) * pio2_1t;
                if (!sign) {
                    val z = x - c;
                    *y0 = z - ct;
                    *y1 = (z - *y0) - ct;
                    return n;
                }
                val z = x + c;
                *y0 = z + ct;
                *y1 = (z - *y0) + ct;
                return -n;
            }
            if (ix < 0x413921FB) {
                return rem_pio2_medium(ix, x, y0, y1); // |x| ~< 2^20 pi/2
            }
            if (ix >= 0x7FF00000) {
                *y0 = x - x; // infinity or NaN
                *y1 = *y0;
                return 0;
            }
            // big: |x| as three 24-bit pieces of z = |x| * 2^(23 - ilogb(x)), for Payne and Hanek's
            // reduction
            var z = from_bits((ux & 0x000FFFFFFFFFFFFF) | (@cast<u64>(0x3FF + 23) << 52));
            var tx: f64[3];
            for (i) in 0..2 {
                tx[i] = @cast<f64>(@cast<i32>(z));
                z = (z - tx[i]) * 16777216.0; // 2^24
            }
            tx[2] = z;
            var nx: i32 = 3;
            while (tx[@cast<usize>(nx - 1)] == 0.0) {
                nx -= 1;
            }
            var ty0 = 0.0;
            var ty1 = 0.0;
            val n = rem_pio2_large(tx[..], &ty0, &ty1, @cast<i32>(ix >> 20) - (0x3FF + 23), nx);
            if (sign) {
                *y0 = -ty0;
                *y1 = -ty1;
                return -n;
            }
            *y0 = ty0;
            *y1 = ty1;
            return n;
        }

        internal val PIO2: f64[8] = {
            1.57079625129699707031e+00, 7.54978941586159635335e-08, 5.39030252995776476554e-15,
            3.28200341580791294123e-22, 1.27065575308067607349e-29, 1.22933308981111328932e-36,
            2.73370053816464559624e-44, 2.16741683877804819444e-51,
        };

        // x (nx 24-bit pieces, x[0] * 2^e0 the first) times 2/pi, its whole part mod 8 returned and
        // the fraction times pi/2 in *y0 + *y1: fdlibm's __kernel_rem_pio2, double precision only
        internal fn rem_pio2_large(x: f64[..], y0: f64&, y1: f64&, e0: i32, nx: i32) -> i32 {
            val jk: i32 = 4;
            val jp = jk;
            var iq: i32[20];
            var f: f64[20];
            var fq: f64[20];
            var q: f64[20];
            // jx, jv and q0 (q0 < 3)
            val jx = nx - 1;
            var jv = (e0 - 3) / 24;
            if (jv < 0) {
                jv = 0;
            }
            var q0 = e0 - 24 * (jv + 1);
            // f[0..jx + jk], with f[jx + jk] = ipio2[jv + jk]
            var j = jv - jx;
            val m = jx + jk;
            for (i) in 0..(m + 1) {
                if (j < 0) {
                    f[@cast<usize>(i)] = 0.0;
                } else {
                    f[@cast<usize>(i)] = @cast<f64>(IPIO2[@cast<usize>(j)]);
                }
                j += 1;
            }
            // q[0..jk]
            for (i) in 0..(jk + 1) {
                var fw = 0.0;
                for (jj) in 0..(jx + 1) {
                    fw += x[@cast<usize>(jj)] * f[@cast<usize>(jx + i - jj)];
                }
                q[@cast<usize>(i)] = fw;
            }
            var jz = jk;
            var z = 0.0;
            var n: i32 = 0;
            var ih: i32 = 0;
            loop {
                // q into iq, in 24-bit pieces, backwards
                z = q[@cast<usize>(jz)];
                var i: i32 = 0;
                var jj = jz;
                while (jj > 0) {
                    val fw = @cast<f64>(@cast<i32>(5.960464477539063e-08 * z)); // 2^-24
                    iq[@cast<usize>(i)] = @cast<i32>(z - 16777216.0 * fw);
                    z = q[@cast<usize>(jj - 1)] + fw;
                    i += 1;
                    jj -= 1;
                }
                // n
                z = scalbn(z, q0);
                z -= 8.0 * floor(z * 0.125); // the whole part mod 8
                n = @cast<i32>(z);
                z -= @cast<f64>(n);
                ih = 0;
                if (q0 > 0) {
                    // iq[jz - 1] has some of n's bits
                    val at = @cast<usize>(jz - 1);
                    val k = iq[at] >> @cast<i32>(24 - q0);
                    n += k;
                    iq[at] -= k << @cast<i32>(24 - q0);
                    ih = iq[at] >> @cast<i32>(23 - q0);
                } else if (q0 == 0) {
                    ih = iq[@cast<usize>(jz - 1)] >> 23;
                } else if (z >= 0.5) {
                    ih = 2;
                }
                if (ih > 0) {
                    // the fraction is over a half: take 1 - it
                    n += 1;
                    var carry: i32 = 0;
                    for (ii) in 0..jz {
                        val v = iq[@cast<usize>(ii)];
                        if (carry == 0) {
                            if (v != 0) {
                                carry = 1;
                                iq[@cast<usize>(ii)] = 0x1000000 - v;
                            }
                        } else {
                            iq[@cast<usize>(ii)] = 0xFFFFFF - v;
                        }
                    }
                    if (q0 == 1) {
                        iq[@cast<usize>(jz - 1)] &= 0x7FFFFF;
                    } else if (q0 == 2) {
                        iq[@cast<usize>(jz - 1)] &= 0x3FFFFF;
                    }
                    if (ih == 2) {
                        z = 1.0 - z;
                        if (carry != 0) {
                            z -= scalbn(1.0, q0);
                        }
                    }
                }
                // more terms when everything cancelled
                if (z != 0.0) {
                    break;
                }
                var any: i32 = 0;
                var ii = jz - 1;
                while (ii >= jk) {
                    any |= iq[@cast<usize>(ii)];
                    ii -= 1;
                }
                if (any != 0) {
                    break;
                }
                var k: i32 = 1;
                while (iq[@cast<usize>(jk - k)] == 0) {
                    k += 1;
                }
                for (i2) in (jz + 1)..(jz + k + 1) {
                    f[@cast<usize>(jx + i2)] = @cast<f64>(IPIO2[@cast<usize>(jv + i2)]);
                    var fw = 0.0;
                    for (jj2) in 0..(jx + 1) {
                        fw += x[@cast<usize>(jj2)] * f[@cast<usize>(jx + i2 - jj2)];
                    }
                    q[@cast<usize>(i2)] = fw;
                }
                jz += k;
            }
            // drop zero pieces, or split z into 24-bit ones
            if (z == 0.0) {
                jz -= 1;
                q0 -= 24;
                while (iq[@cast<usize>(jz)] == 0) {
                    jz -= 1;
                    q0 -= 24;
                }
            } else {
                z = scalbn(z, -q0);
                if (z >= 16777216.0) {
                    val fw = @cast<f64>(@cast<i32>(5.960464477539063e-08 * z));
                    iq[@cast<usize>(jz)] = @cast<i32>(z - 16777216.0 * fw);
                    jz += 1;
                    q0 += 24;
                    iq[@cast<usize>(jz)] = @cast<i32>(fw);
                } else {
                    iq[@cast<usize>(jz)] = @cast<i32>(z);
                }
            }
            // the pieces back to floating point
            var fw = scalbn(1.0, q0);
            var i3 = jz;
            while (i3 >= 0) {
                q[@cast<usize>(i3)] = fw * @cast<f64>(iq[@cast<usize>(i3)]);
                fw *= 5.960464477539063e-08;
                i3 -= 1;
            }
            // times pi/2
            i3 = jz;
            while (i3 >= 0) {
                var s = 0.0;
                var k: i32 = 0;
                while (k <= jp && k <= jz - i3) {
                    s += PIO2[@cast<usize>(k)] * q[@cast<usize>(i3 + k)];
                    k += 1;
                }
                fq[@cast<usize>(jz - i3)] = s;
                i3 -= 1;
            }
            // into two doubles
            var s = 0.0;
            i3 = jz;
            while (i3 >= 0) {
                s += fq[@cast<usize>(i3)];
                i3 -= 1;
            }
            if (ih == 0) {
                *y0 = s;
            } else {
                *y0 = -s;
            }
            s = fq[0] - s;
            for (i4) in 1..(jz + 1) {
                s += fq[@cast<usize>(i4)];
            }
            if (ih == 0) {
                *y1 = s;
            } else {
                *y1 = -s;
            }
            return n & 7;
        }

        // the sine, x in radians
        fn sin(x: f64) -> f64 {
            val ix = high(x) & 0x7FFFFFFF;
            if (ix <= 0x3FE921FB) {
                // |x| ~< pi/4
                if (ix < 0x3E500000) {
                    return x; // |x| < 2^-26
                }
                return sin_kernel(x, 0.0, 0);
            }
            if (ix >= 0x7FF00000) {
                return x - x; // NaN
            }
            var y0 = 0.0;
            var y1 = 0.0;
            val n = rem_pio2(x, &y0, &y1) & 3;
            if (n == 0) {
                return sin_kernel(y0, y1, 1);
            }
            if (n == 1) {
                return cos_kernel(y0, y1);
            }
            if (n == 2) {
                return -sin_kernel(y0, y1, 1);
            }
            return -cos_kernel(y0, y1);
        }

        // the cosine, x in radians
        fn cos(x: f64) -> f64 {
            val ix = high(x) & 0x7FFFFFFF;
            if (ix <= 0x3FE921FB) {
                if (ix < 0x3E46A09E) {
                    return 1.0; // |x| < 2^-27 sqrt(2)
                }
                return cos_kernel(x, 0.0);
            }
            if (ix >= 0x7FF00000) {
                return x - x;
            }
            var y0 = 0.0;
            var y1 = 0.0;
            val n = rem_pio2(x, &y0, &y1) & 3;
            if (n == 0) {
                return cos_kernel(y0, y1);
            }
            if (n == 1) {
                return -sin_kernel(y0, y1, 1);
            }
            if (n == 2) {
                return -cos_kernel(y0, y1);
            }
            return sin_kernel(y0, y1, 1);
        }

        // the tangent, x in radians
        fn tan(x: f64) -> f64 {
            val ix = high(x) & 0x7FFFFFFF;
            if (ix <= 0x3FE921FB) {
                if (ix < 0x3E400000) {
                    return x; // |x| < 2^-27
                }
                return tan_kernel(x, 0.0, false);
            }
            if (ix >= 0x7FF00000) {
                return x - x;
            }
            var y0 = 0.0;
            var y1 = 0.0;
            val n = rem_pio2(x, &y0, &y1);
            return tan_kernel(y0, y1, (n & 1) != 0);
        }

        // asin and acos's rational approximation
        internal fn asin_r(z: f64) -> f64 {
            val p = z * (1.66666666666666657415e-01 + z * (-3.25565818622400915405e-01 + z * (2.01212532134862925881e-01 + z * (-4.00555345006794114027e-02 + z * (7.91534994289814532176e-04 + z * 3.47933107596021167570e-05)))));
            val q = 1.0 + z * (-2.40339491173441421878e+00 + z * (2.02094576023350569471e+00 + z * (-6.88283971605453293030e-01 + z * 7.70381505559019352791e-02)));
            return p / q;
        }

        internal val PIO2_HI = 1.57079632679489655800e+00;
        internal val PIO2_LO = 6.12323399573676603587e-17;

        // the angle whose sine is x, in radians (-pi/2 to pi/2)
        fn asin(x: f64) -> f64 {
            val hx = high(x);
            val ix = hx & 0x7FFFFFFF;
            if (ix >= 0x3FF00000) {
                // |x| >= 1 or NaN
                val lx = @cast<u32>(bits(x) & 0xFFFFFFFF);
                if (((ix - 0x3FF00000) | lx) == 0) {
                    return x * PIO2_HI + 7.52316384526264e-37; // +-pi/2
                }
                return 0.0 / (x - x);
            }
            if (ix < 0x3FE00000) {
                // |x| < 0.5
                if (ix < 0x3E500000 && ix >= 0x00100000) {
                    return x;
                }
                return x + x * asin_r(x * x);
            }
            // 1 > |x| >= 0.5
            var ax = x;
            if (ax < 0.0) {
                ax = -ax;
            }
            val z = (1.0 - ax) * 0.5;
            val s = sqrt(z);
            val r = asin_r(z);
            var y = 0.0;
            if (ix >= 0x3FEF3333) {
                // |x| > 0.975
                y = PIO2_HI - (2.0 * (s + s * r) - PIO2_LO);
            } else {
                // f + c = sqrt(z)
                val f = from_bits(bits(s) & 0xFFFFFFFF00000000);
                val c = (z - f * f) / (s + f);
                y = 0.5 * PIO2_HI - (2.0 * s * r - (PIO2_LO - 2.0 * c) - (0.5 * PIO2_HI - 2.0 * f));
            }
            if ((hx >> 31) != 0) {
                return -y;
            }
            return y;
        }

        // the angle whose cosine is x, in radians (0 to pi)
        fn acos(x: f64) -> f64 {
            val hx = high(x);
            val ix = hx & 0x7FFFFFFF;
            if (ix >= 0x3FF00000) {
                val lx = @cast<u32>(bits(x) & 0xFFFFFFFF);
                if (((ix - 0x3FF00000) | lx) == 0) {
                    if ((hx >> 31) != 0) {
                        return 2.0 * PIO2_HI + 7.52316384526264e-37; // pi
                    }
                    return 0.0;
                }
                return 0.0 / (x - x);
            }
            if (ix < 0x3FE00000) {
                // |x| < 0.5
                if (ix <= 0x3C600000) {
                    return PIO2_HI + 7.52316384526264e-37; // |x| < 2^-57
                }
                return PIO2_HI - (x - (PIO2_LO - x * asin_r(x * x)));
            }
            if ((hx >> 31) != 0) {
                // x < -0.5
                val z = (1.0 + x) * 0.5;
                val s = sqrt(z);
                val w = asin_r(z) * s - PIO2_LO;
                return 2.0 * (PIO2_HI - (s + w));
            }
            // x > 0.5
            val z = (1.0 - x) * 0.5;
            val s = sqrt(z);
            val df = from_bits(bits(s) & 0xFFFFFFFF00000000);
            val c = (z - df * df) / (s + df);
            val w = asin_r(z) * s + c;
            return 2.0 * (df + w);
        }

        internal val ATAN_HI: f64[4] = { 4.63647609000806093515e-01, 7.85398163397448278999e-01, 9.82793723247329054082e-01, 1.57079632679489655800e+00 };
        internal val ATAN_LO: f64[4] = { 2.26987774529616870924e-17, 3.06161699786838301793e-17, 1.39033110312309984516e-17, 6.12323399573676603587e-17 };
        internal val ATAN_T: f64[11] = {
            3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01,
            -1.11111104054623557880e-01, 9.09088713343650656196e-02, -7.69187620504482999495e-02,
            6.66107313738753120669e-02, -5.83357013379057348645e-02, 4.97687799461593236017e-02,
            -3.65315727442169155270e-02, 1.62858201153657823623e-02,
        };

        // the angle whose tangent is x, in radians (-pi/2 to pi/2)
        fn atan(x0: f64) -> f64 {
            val hx = bits(x0);
            val ix = @cast<u32>(hx >> 32) & 0x7FFFFFFF;
            val sign = (hx >> 63) != 0;
            if (ix >= 0x44100000) {
                // |x| >= 2^66
                if (x0 != x0) {
                    return x0;
                }
                val z = ATAN_HI[3] + 7.52316384526264e-37;
                if (sign) {
                    return -z;
                }
                return z;
            }
            var x = x0;
            var id: i32 = -1;
            if (ix < 0x3FDC0000) {
                // |x| < 0.4375
                if (ix < 0x3E400000) {
                    return x; // |x| < 2^-27
                }
            } else {
                if (x < 0.0) {
                    x = -x;
                }
                if (ix < 0x3FF30000) {
                    // |x| < 1.1875
                    if (ix < 0x3FE60000) {
                        id = 0; // 7/16 <= |x| < 11/16
                        x = (2.0 * x - 1.0) / (2.0 + x);
                    } else {
                        id = 1; // 11/16 <= |x| < 19/16
                        x = (x - 1.0) / (x + 1.0);
                    }
                } else if (ix < 0x40038000) {
                    id = 2; // |x| < 2.4375
                    x = (x - 1.5) / (1.0 + 1.5 * x);
                } else {
                    id = 3; // 2.4375 <= |x| < 2^66
                    x = -1.0 / x;
                }
            }
            val z = x * x;
            val w = z * z;
            val s1 = z * (ATAN_T[0] + w * (ATAN_T[2] + w * (ATAN_T[4] + w * (ATAN_T[6] + w * (ATAN_T[8] + w * ATAN_T[10])))));
            val s2 = w * (ATAN_T[1] + w * (ATAN_T[3] + w * (ATAN_T[5] + w * (ATAN_T[7] + w * ATAN_T[9]))));
            if (id < 0) {
                return x - x * (s1 + s2);
            }
            val at = @cast<usize>(id);
            val r = ATAN_HI[at] - (x * (s1 + s2) - ATAN_LO[at] - x);
            if (sign) {
                return -r;
            }
            return r;
        }

        // the angle of the point (x, y) from the x axis, in radians (-pi to pi)
        fn atan2(y: f64, x: f64) -> f64 {
            val pi = 3.1415926535897931160e+00;
            val pi_lo = 1.2246467991473531772e-16;
            if (x != x || y != y) {
                return x + y;
            }
            val ux = bits(x);
            var ix = @cast<u32>(ux >> 32);
            val lx = @cast<u32>(ux & 0xFFFFFFFF);
            val uy = bits(y);
            var iy = @cast<u32>(uy >> 32);
            val ly = @cast<u32>(uy & 0xFFFFFFFF);
            if (((ix -% 0x3FF00000) | lx) == 0) {
                return atan(y); // x is 1
            }
            // 2 * sign(x) + sign(y)
            val m = ((iy >> 31) & 1) | ((ix >> 30) & 2);
            ix &= 0x7FFFFFFF;
            iy &= 0x7FFFFFFF;
            if ((iy | ly) == 0) {
                // y is 0
                if (m <= 1) {
                    return y;
                }
                if (m == 2) {
                    return pi;
                }
                return -pi;
            }
            if ((ix | lx) == 0) {
                // x is 0
                if ((m & 1) != 0) {
                    return -pi / 2.0;
                }
                return pi / 2.0;
            }
            if (ix == 0x7FF00000) {
                // x is infinite
                if (iy == 0x7FF00000) {
                    if (m == 0) {
                        return pi / 4.0;
                    }
                    if (m == 1) {
                        return -pi / 4.0;
                    }
                    if (m == 2) {
                        return 3.0 * pi / 4.0;
                    }
                    return -3.0 * pi / 4.0;
                }
                if (m == 0) {
                    return 0.0;
                }
                if (m == 1) {
                    return -0.0;
                }
                if (m == 2) {
                    return pi;
                }
                return -pi;
            }
            if (ix +% 0x4000000 < iy || iy == 0x7FF00000) {
                // |y/x| > 2^64
                if ((m & 1) != 0) {
                    return -pi / 2.0;
                }
                return pi / 2.0;
            }
            var z = 0.0;
            if ((m & 2) == 0 || iy +% 0x4000000 >= ix) {
                var q = y / x;
                if (q < 0.0) {
                    q = -q;
                }
                z = atan(q);
            }
            if (m == 0) {
                return z;
            }
            if (m == 1) {
                return -z;
            }
            if (m == 2) {
                return pi - (z - pi_lo);
            }
            return (z - pi_lo) - pi;
        }

        // ---------- hyperbolic ----------

        // the hyperbolic sine
        fn sinh(x: f64) -> f64 {
            val u = bits(x);
            val w = @cast<u32>(u >> 32) & 0x7FFFFFFF;
            val ax = from_bits(u & 0x7FFFFFFFFFFFFFFF);
            if (x == 0.0 || x != x) {
                return x;
            }
            var h = 0.5;
            if ((u >> 63) != 0) {
                h = -h;
            }
            if (w < 0x40862E42) {
                // |x| < log(DBL_MAX)
                val t = expm1(ax);
                if (w < 0x3FF00000) {
                    if (w < 0x3E500000) {
                        return x;
                    }
                    return h * (2.0 * t - t * t / (t + 1.0));
                }
                return h * (t + t / (t + 1.0));
            }
            return 2.0 * h * expo2(ax);
        }

        // the hyperbolic cosine
        fn cosh(x: f64) -> f64 {
            val u = bits(x);
            val w = @cast<u32>(u >> 32) & 0x7FFFFFFF;
            val ax = from_bits(u & 0x7FFFFFFFFFFFFFFF);
            if (w < 0x3FE62E42) {
                // |x| < log(2)
                if (w < 0x3E500000) {
                    return 1.0;
                }
                val t = expm1(ax);
                return 1.0 + t * t / (2.0 * (1.0 + t));
            }
            if (w < 0x40862E42) {
                // |x| < log(DBL_MAX)
                val t = exp(ax);
                return 0.5 * (t + 1.0 / t);
            }
            return expo2(ax); // overflows, or NaN
        }

        // the hyperbolic tangent
        fn tanh(x: f64) -> f64 {
            val u = bits(x);
            val ux = u & 0x7FFFFFFFFFFFFFFF;
            val w = @cast<u32>(ux >> 32);
            val ax = from_bits(ux);
            var t = 0.0;
            if (w > 0x3FE193EA) {
                // |x| > log(3)/2 or NaN
                if (w > 0x40340000) {
                    t = 1.0 - 0.0 / ax; // |x| > 20 or NaN
                } else {
                    t = expm1(2.0 * ax);
                    t = 1.0 - 2.0 / (t + 2.0);
                }
            } else if (w > 0x3FD058AE) {
                // |x| > log(5/3)/2
                t = expm1(2.0 * ax);
                t = t / (t + 2.0);
            } else if (w >= 0x00100000) {
                t = expm1(-2.0 * ax);
                t = -t / (t + 2.0);
            } else {
                t = ax; // subnormal
            }
            if ((u >> 63) != 0) {
                return -t;
            }
            return t;
        }

        // ---------- f32: through f64, rounded once ----------
        // (an f32 is exact as an f64; sqrt, floor, ceil, round, trunc and fmod stay exact, the rest are
        // within an ulp)

        // the square root
        fn sqrt(x: f32) -> f32 { return @cast<f32>(sqrt(@cast<f64>(x))); }
        // the cube root
        fn cbrt(x: f32) -> f32 { return @cast<f32>(cbrt(@cast<f64>(x))); }
        // x to the power y
        fn pow(x: f32, y: f32) -> f32 { return @cast<f32>(pow(@cast<f64>(x), @cast<f64>(y))); }
        // e to the power x
        fn exp(x: f32) -> f32 { return @cast<f32>(exp(@cast<f64>(x))); }
        // 2 to the power x
        fn exp2(x: f32) -> f32 { return @cast<f32>(exp2(@cast<f64>(x))); }
        // e to the power x, minus 1
        fn expm1(x: f32) -> f32 { return @cast<f32>(expm1(@cast<f64>(x))); }
        // the natural logarithm (base e)
        fn log(x: f32) -> f32 { return @cast<f32>(log(@cast<f64>(x))); }
        // the base-2 logarithm
        fn log2(x: f32) -> f32 { return @cast<f32>(log2(@cast<f64>(x))); }
        // the base-10 logarithm
        fn log10(x: f32) -> f32 { return @cast<f32>(log10(@cast<f64>(x))); }
        // the sine of x radians
        fn sin(x: f32) -> f32 { return @cast<f32>(sin(@cast<f64>(x))); }
        // the cosine of x radians
        fn cos(x: f32) -> f32 { return @cast<f32>(cos(@cast<f64>(x))); }
        // the tangent of x radians
        fn tan(x: f32) -> f32 { return @cast<f32>(tan(@cast<f64>(x))); }
        // the arcsine, in radians
        fn asin(x: f32) -> f32 { return @cast<f32>(asin(@cast<f64>(x))); }
        // the arccosine, in radians
        fn acos(x: f32) -> f32 { return @cast<f32>(acos(@cast<f64>(x))); }
        // the arctangent, in radians
        fn atan(x: f32) -> f32 { return @cast<f32>(atan(@cast<f64>(x))); }
        // the angle of the point (x, y) from the x axis, in radians (-pi to pi)
        fn atan2(y: f32, x: f32) -> f32 { return @cast<f32>(atan2(@cast<f64>(y), @cast<f64>(x))); }
        // the hyperbolic sine
        fn sinh(x: f32) -> f32 { return @cast<f32>(sinh(@cast<f64>(x))); }
        // the hyperbolic cosine
        fn cosh(x: f32) -> f32 { return @cast<f32>(cosh(@cast<f64>(x))); }
        // the hyperbolic tangent
        fn tanh(x: f32) -> f32 { return @cast<f32>(tanh(@cast<f64>(x))); }
        // the length of the hypotenuse, sqrt(x*x + y*y) without overflowing
        fn hypot(x: f32, y: f32) -> f32 { return @cast<f32>(hypot(@cast<f64>(x), @cast<f64>(y))); }
        // the largest whole number not above x
        fn floor(x: f32) -> f32 { return @cast<f32>(floor(@cast<f64>(x))); }
        // the smallest whole number not below x
        fn ceil(x: f32) -> f32 { return @cast<f32>(ceil(@cast<f64>(x))); }
        // the nearest whole number, halves away from zero
        fn round(x: f32) -> f32 { return @cast<f32>(round(@cast<f64>(x))); }
        // x without its fraction (toward zero)
        fn trunc(x: f32) -> f32 { return @cast<f32>(trunc(@cast<f64>(x))); }
        // the remainder of x / y, with x's sign
        fn fmod(x: f32, y: f32) -> f32 { return @cast<f32>(fmod(@cast<f64>(x), @cast<f64>(y))); }

        // 2^(k/128) ~= H[k] * (1 + T[k]): [2k] the bits of T[k], [2k + 1] the bits of H[k] - (k << 45)
        internal val EXP_TAB: u64[256] = {
            0x0, 0x3ff0000000000000, 0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
            0xbc7160139cd8dc5d, 0x3fefec9a3e778061, 0xbc905e7a108766d1, 0x3fefe315e86e7f85,
            0x3c8cd2523567f613, 0x3fefd9b0d3158574, 0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
            0x3c60f74e61e6c861, 0x3fefc74518759bc8, 0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
            0x3c979aa65d837b6d, 0x3fefb5586cf9890f, 0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
            0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2, 0xbc6a033489906e0b, 0x3fef9b66affed31b,
            0xbc9556522a2fbd0e, 0x3fef9301d0125b51, 0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
            0xbc91c923b9d5f416, 0x3fef829aaea92de0, 0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
            0xbc801b15eaa59348, 0x3fef72b83c7d517b, 0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
            0x3c8b898c3f1353bf, 0x3fef635beb6fcb75, 0xbc96d99c7611eb26, 0x3fef5be084045cd4,
            0x3c9aecf73e3a2f60, 0x3fef54873168b9aa, 0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
            0x3c8a6f4144a6c38d, 0x3fef463b88628cd6, 0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
            0x3c968efde3a8a894, 0x3fef387a6e756238, 0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
            0x3c80472b981fe7f2, 0x3fef2b4565e27cdd, 0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
            0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1, 0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
            0x3c8b3782720c0ab4, 0x3fef1285a6e4030b, 0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
            0x3c834d754db0abb6, 0x3fef06fe0a31b715, 0x3c864201e2ac744c, 0x3fef0170fc4cd831,
            0x3c8fdd395dd3f84a, 0x3feefc08b26416ff, 0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
            0xbc924aedcc4b5068, 0x3feef1a7373aa9cb, 0xbc9907f81b512d8e, 0x3feeecae6d05d866,
            0xbc71d1e83e9436d2, 0x3feee7db34e59ff7, 0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
            0x3c859f48a72a4c6d, 0x3feedea64c123422, 0xbc9312607a28698a, 0x3feeda4504ac801c,
            0xbc58a78f4817895b, 0x3feed60a21f72e2a, 0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
            0x3c4363ed60c2ac11, 0x3feece086061892d, 0x3c9666093b0664ef, 0x3feeca41ed1d0057,
            0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0, 0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
            0x3c7690cebb7aafb0, 0x3feebfdad5362a27, 0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
            0xbc8f94340071a38e, 0x3feeb9b2769d2ca7, 0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
            0xbc78dec6bd0f385f, 0x3feeb42b569d4f82, 0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
            0x3c93350518fdd78e, 0x3feeaf4736b527da, 0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
            0x3c9063e1e21c5409, 0x3feeab07dd485429, 0x3c34c7855019c6ea, 0x3feea9268a5946b7,
            0x3c9432e62b64c035, 0x3feea76f15ad2148, 0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
            0xbc8c33c53bef4da8, 0x3feea47eb03a5585, 0xbc845378892be9ae, 0x3feea34634ccc320,
            0xbc93cedd78565858, 0x3feea23882552225, 0x3c5710aa807e1964, 0x3feea155d44ca973,
            0xbc93b3efbf5e2228, 0x3feea09e667f3bcd, 0xbc6a12ad8734b982, 0x3feea012750bdabf,
            0xbc6367efb86da9ee, 0x3fee9fb23c651a2f, 0xbc80dc3d54e08851, 0x3fee9f7df9519484,
            0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74, 0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
            0xbc8619321e55e68a, 0x3fee9feb564267c9, 0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
            0xbc7b32dcb94da51d, 0x3feea11473eb0187, 0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
            0x3c65ebe1abd66c55, 0x3feea2f336cf4e62, 0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
            0xbc9369b6f13b3734, 0x3feea589994cce13, 0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
            0xbc94d450d872576e, 0x3feea8d99b4492ed, 0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
            0x3c8db72fc1f0eab4, 0x3feeace5422aa0db, 0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
            0x3c7bf68359f35f44, 0x3feeb1ae99157736, 0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
            0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5, 0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
            0xbc92434322f4f9aa, 0x3feebd829fde4e50, 0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
            0x3c71affc2b91ce27, 0x3feec49182a3f090, 0x3c6dd235e10a73bb, 0x3feec86319e32323,
            0xbc87c50422622263, 0x3feecc667b5de565, 0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
            0xbc91bbd1d3bcbb15, 0x3feed503b23e255d, 0x3c90cc319cee31d2, 0x3feed99e1330b358,
            0x3c8469846e735ab3, 0x3feede6b5579fdbf, 0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
            0x3c8c1a7792cb3387, 0x3feee89f995ad3ad, 0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
            0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb, 0xbc90a40e3da6f640, 0x3feef9728de5593a,
            0xbc68d6f438ad9334, 0x3feeff76f2fb5e47, 0xbc91eee26b588a35, 0x3fef05b030a1064a,
            0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2, 0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
            0x3c736eae30af0cb3, 0x3fef199bdd85529c, 0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
            0x3c84e08fd10959ac, 0x3fef27f12e57d14b, 0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
            0x3c676b2c6c921968, 0x3fef3720dcef9069, 0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
            0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c, 0xbc900dae3875a949, 0x3fef4f87080d89f2,
            0x3c74a385a63d07a7, 0x3fef5818dcfba487, 0xbc82919e2040220f, 0x3fef60e316c98398,
            0x3c8e5a50d5c192ac, 0x3fef69e603db3285, 0x3c843a59ac016b4b, 0x3fef7321f301b460,
            0xbc82d52107b43e1f, 0x3fef7c97337b9b5f, 0xbc892ab93b470dc9, 0x3fef864614f5a129,
            0x3c74b604603a88d3, 0x3fef902ee78b3ff6, 0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
            0xbc8ff7128fd391f0, 0x3fefa4afa2a490da, 0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
            0x3c8ec3bc41aa2008, 0x3fefba1bee615a27, 0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
            0x3c8a64a931d185ee, 0x3fefd0765b6e4540, 0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
            0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8, 0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
        };
        // for log in pow: 1/c, log(c) to 43 bits, and the rest of log(c), for 128 intervals
        internal val POW_LOG_TAB: f64[384] = {
            1.4140625, -0.3464667673462145, 5.929407345889625e-15,
            1.40625, -0.34092658697056777, -2.544157440035963e-14,
            1.3984375, -0.3353555419211034, -3.443525940775045e-14,
            1.390625, -0.3297532863724655, -2.500123826022799e-15,
            1.3828125, -0.32411946865420305, -8.929337133850617e-15,
            1.375, -0.31845373111855224, 1.7625431312172662e-14,
            1.3671875, -0.31275571000389846, 1.5688303180062087e-15,
            1.359375, -0.3070250352949415, 2.9655274673691784e-14,
            1.3515625, -0.3012613305781997, 3.7923164802093147e-14,
            1.34375, -0.2954642128938758, 3.993416384387844e-14,
            1.3359375, -0.28963329258306203, 1.9352855826489123e-14,
            1.3359375, -0.28963329258306203, 1.9352855826489123e-14,
            1.328125, -0.28376817313062475, -1.9852665484979036e-14,
            1.3203125, -0.27786845100342816, -2.814323765595281e-14,
            1.3125, -0.2719337154836694, 2.7643769993528702e-14,
            1.3046875, -0.2659635484970977, -4.025092402293806e-14,
            1.296875, -0.25995752443691345, -1.2621729398885316e-14,
            1.2890625, -0.25391520998095984, -3.600176732637335e-15,
            1.2890625, -0.25391520998095984, -3.600176732637335e-15,
            1.28125, -0.2478361639045943, 1.3029797173308663e-14,
            1.2734375, -0.2417199368871934, 4.8230289429940886e-14,
            1.265625, -0.23556607131274632, -2.0592242769647135e-14,
            1.2578125, -0.22937410106487732, 3.149265065191484e-14,
            1.25, -0.22314355131425145, 4.169796584527195e-14,
            1.25, -0.22314355131425145, 4.169796584527195e-14,
            1.2421875, -0.21687393830063684, 2.2477465222466186e-14,
            1.234375, -0.21056476910735, 3.6507188831790577e-16,
            1.2265625, -0.2042155414286526, -3.827767260205414e-14,
            1.2265625, -0.2042155414286526, -3.827767260205414e-14,
            1.21875, -0.19782574332987224, -4.7641388950792196e-14,
            1.2109375, -0.19139485299967873, 4.9278276214647115e-14,
            1.203125, -0.18492233849406148, 4.9485167661250996e-14,
            1.203125, -0.18492233849406148, 4.9485167661250996e-14,
            1.1953125, -0.1784076574728033, -1.5003333854266542e-14,
            1.1875, -0.17185025692663203, -2.7194441649495324e-14,
            1.1875, -0.17185025692663203, -2.7194441649495324e-14,
            1.1796875, -0.1652495728952772, -2.99659267292569e-14,
            1.171875, -0.15860503017665906, 2.0472357800461955e-14,
            1.171875, -0.15860503017665906, 2.0472357800461955e-14,
            1.1640625, -0.15191604202584585, 3.879296723063646e-15,
            1.15625, -0.1451820098444614, -3.6506824353335045e-14,
            1.1484375, -0.13840232285906495, -5.4183331379008994e-14,
            1.1484375, -0.13840232285906495, -5.4183331379008994e-14,
            1.140625, -0.131576357788731, 1.1729485484531301e-14,
            1.140625, -0.131576357788731, 1.1729485484531301e-14,
            1.1328125, -0.12470347850091912, -3.811763084710266e-14,
            1.125, -0.11778303565643, 4.654729747598445e-14,
            1.125, -0.11778303565643, 4.654729747598445e-14,
            1.1171875, -0.11081436634026431, -2.5799991283069902e-14,
            1.109375, -0.10379679368168127, 3.7700471749674615e-14,
            1.109375, -0.10379679368168127, 3.7700471749674615e-14,
            1.1015625, -0.09672962645856842, 1.7306161136093256e-14,
            1.1015625, -0.09672962645856842, 1.7306161136093256e-14,
            1.09375, -0.089612158689647, -4.012913552726574e-14,
            1.0859375, -0.08244366921110213, 2.7541708360737882e-14,
            1.0859375, -0.08244366921110213, 2.7541708360737882e-14,
            1.078125, -0.07522342123763792, 5.0396178134370583e-14,
            1.078125, -0.07522342123763792, 5.0396178134370583e-14,
            1.0703125, -0.06795066190852594, 1.8195060030168815e-14,
            1.0625, -0.06062462181648698, 5.213620639136504e-14,
            1.0625, -0.06062462181648698, 5.213620639136504e-14,
            1.0546875, -0.053244514518837605, 2.532168943117445e-14,
            1.0546875, -0.053244514518837605, 2.532168943117445e-14,
            1.046875, -0.045809536031242715, -5.148849572685811e-14,
            1.046875, -0.045809536031242715, -5.148849572685811e-14,
            1.0390625, -0.038318864302141264, 4.6652946995830086e-15,
            1.0390625, -0.038318864302141264, 4.6652946995830086e-15,
            1.03125, -0.03077165866670839, -4.529814257790929e-14,
            1.03125, -0.03077165866670839, -4.529814257790929e-14,
            1.0234375, -0.023167059281490765, -4.361324067851568e-14,
            1.015625, -0.015504186535963527, -1.7274567499706107e-15,
            1.015625, -0.015504186535963527, -1.7274567499706107e-15,
            1.0078125, -0.0077821404420319595, -2.298941004620351e-14,
            1.0078125, -0.0077821404420319595, -2.298941004620351e-14,
            1.0, 0.0, 0.0,
            1.0, 0.0, 0.0,
            0.9921875, 0.007843177461040796, -1.4902732911301337e-14,
            0.984375, 0.01574835696817445, -3.527980389655325e-14,
            0.9765625, 0.023716526617363343, -4.730054772033249e-14,
            0.96875, 0.03174869831457272, 7.580310369375161e-15,
            0.9609375, 0.039845908547249564, -4.9893776716773285e-14,
            0.953125, 0.048009219186383234, -2.262629393030674e-14,
            0.9453125, 0.056239718322899535, -2.345674491018699e-14,
            0.94140625, 0.06038051098892083, -1.3352588834854848e-14,
            0.93359375, 0.06871389254808946, -3.765296820388875e-14,
            0.92578125, 0.07711730334438016, 5.1128335719851986e-14,
            0.91796875, 0.08559193033545398, -5.046674438470119e-14,
            0.9140625, 0.08985632912185793, 3.1218748807418837e-15,
            0.90625, 0.09844007281321865, 3.3871241029241416e-14,
            0.8984375, 0.10709813555638448, -1.7376727386423858e-14,
            0.89453125, 0.11145544092528326, 3.957125899799804e-14,
            0.88671875, 0.12022742699821265, -5.2849453521890294e-14,
            0.8828125, 0.12464244520731427, -3.767012502308738e-14,
            0.875, 0.13353139262449076, 3.1859736349078334e-14,
            0.87109375, 0.13800567301939282, 5.0900642926060466e-14,
            0.86328125, 0.14701474296180095, 8.710783796122478e-15,
            0.859375, 0.15154989812720032, 6.157896229122976e-16,
            0.8515625, 0.16068238169043525, 3.821577743916796e-14,
            0.84765625, 0.16528009093906348, 3.9440046718453496e-14,
            0.83984375, 0.17453941635187675, 2.2924522154618074e-14,
            0.8359375, 0.17920142945774842, -3.742530094732263e-14,
            0.83203125, 0.18388527877016259, -2.5223102140407338e-14,
            0.82421875, 0.1933193110035063, -1.0320443688698849e-14,
            0.8203125, 0.19806991376208316, 1.0634128304268335e-14,
            0.8125, 0.20763936477828793, -4.3425422595242564e-14,
            0.80859375, 0.21245865121420593, -1.2527395755711364e-14,
            0.8046875, 0.21730127569003344, -5.204008743405884e-14,
            0.80078125, 0.22216746534115828, -3.979844515951702e-15,
            0.79296875, 0.2319714654378231, -4.7955860343296286e-14,
            0.7890625, 0.2369097470783572, 5.015686013791602e-16,
            0.78515625, 0.24187253642048745, -7.252318953240293e-16,
            0.78125, 0.2468600779315011, 2.4688324156011588e-14,
            0.7734375, 0.2569104137850218, 5.465121253624792e-15,
            0.76953125, 0.26197371574153294, 4.102651071698446e-14,
            0.765625, 0.2670627852490952, -4.996736502345936e-14,
            0.76171875, 0.27217788591576664, 4.903580708156347e-14,
            0.7578125, 0.27731928541618345, 5.089628039500759e-14,
            0.75390625, 0.28248725557466514, 1.1782016386565151e-14,
            0.74609375, 0.29290401643288533, 4.727452940514406e-14,
            0.7421875, 0.29815337231912054, -4.4204083338755686e-14,
            0.73828125, 0.3034304294199046, 1.548345993498083e-14,
            0.734375, 0.30873548164959175, 2.1522127491642888e-14,
            0.73046875, 0.3140688276249648, 1.1054030169005386e-14,
            0.7265625, 0.31943077076641657, -5.534326352070679e-14,
            0.72265625, 0.3248216194012912, -5.351646604259541e-14,
            0.71875, 0.33024168687052224, 5.4612144489920215e-14,
            0.71484375, 0.3356912916381134, 2.8136969901227338e-14,
            0.7109375, 0.3411707574027787, -1.156568624616423e-14,
        };
        // exp2's table: [2i] 2^(i/256 + eps[i]), [2i + 1] eps[i]
        internal val EXP2_TAB: f64[512] = {
            0.707106781186592, 9.070522111187529e-14,
            0.7090239421602083, 1.3322676295501878e-15,
            0.7109463010845614, -4.346523141407488e-14,
            0.7128738720527606, 2.731148640577885e-14,
            0.7148066691959843, -1.3322676295501878e-15,
            0.7167447066838942, -3.885780586188048e-16,
            0.718687998724463, -5.6565863104651726e-14,
            0.7206365595642875, -5.0681681074138396e-14,
            0.7225904034885321, 1.7541523789077473e-14,
            0.7245495448209743, -8.593126210598712e-14,
            0.7265139979245225, -7.438494264988549e-15,
            0.7284837772007502, 5.601075159233915e-14,
            0.730458897090328, 8.826273045769994e-15,
            0.7324393720731814, -4.2299497238218464e-14,
            0.7344252166684901, -1.609823385706477e-15,
            0.7364164454346849, 2.1094237467877974e-15,
            0.738413072969748, -3.219646771412954e-15,
            0.7404151139112507, 2.886579864025407e-14,
            0.7424225829363763, 1.1102230246251565e-16,
            0.7444354947621779, -4.007905118896815e-14,
            0.7464538641456281, -8.382183835919932e-15,
            0.748477705883599, -3.6137759451548845e-14,
            0.7505070348132479, 6.750155989720952e-14,
            0.7525418658117105, 1.3766765505351941e-14,
            0.7545822137966949, -3.1530333899354446e-14,
            0.756628093726329, 4.5852210917018965e-14,
            0.7586795205991935, 1.638689184346731e-13,
            0.7607365094544245, 3.26405569239796e-14,
            0.7627990753722339, -6.666889262874065e-14,
            0.7648672334736256, -3.375077994860476e-14,
            0.766940998920453, -4.707345624410664e-14,
            0.7690203869158267, -3.219646771412954e-15,
            0.7711054127040068, 6.80566714095221e-14,
            0.773196091570582, 1.3289369604763124e-13,
            0.7752924388424706, -5.473399511402022e-14,
            0.7773944698885287, -2.8976820942716586e-14,
            0.7795022001189417, 4.29101199017623e-14,
            0.781615644985665, -2.5479618415147343e-14,
            0.7837348199827712, -9.71445146547012e-15,
            0.7858597406461733, 4.718447854656915e-15,
            0.7879904225539545, 2.0539125955565396e-14,
            0.7901268813264062, -1.1102230246251565e-14,
            0.7922691326262677, 3.802513859341161e-14,
            0.7944171921585373, -8.104628079763643e-14,
            0.7965710756711293, -7.549516567451064e-15,
            0.7987307989543421, 5.1514348342607263e-14,
            0.8008963778412981, -8.754108549169359e-14,
            0.8030678282084277, 7.588374373312945e-14,
            0.8052451659746497, 4.035660694512444e-14,
            0.8074284071024286, -3.1086244689504383e-15,
            0.8096175675974437, 2.1149748619109232e-14,
            0.8118126635086755, 1.9761969838327786e-14,
            0.8140137109286713, -4.6629367034256575e-15,
            0.816220725993644, 1.149080830487037e-14,
            0.8184337248835093, 4.7684078907650473e-14,
            0.8206527238219895, -2.3925306180672123e-14,
            0.8228777390769894, 1.2156942119645464e-14,
            0.8251087869603587, 8.715250743307479e-14,
            0.8273458838281059, 1.5210055437364645e-14,
            0.8295890460808139, 1.0103029524088925e-14,
            0.8318382901633419, -4.568567746332519e-14,
            0.8340936325653194, 4.873879078104437e-14,
            0.8363550898207991, 1.3877787807814457e-15,
            0.8386226785089406, 2.220446049250313e-15,
            0.840896415253685, -5.0737192225369654e-14,
            0.8431763167242082, 1.9817480989559044e-14,
            0.8454623996346857, 5.6538107529036097e-14,
            0.847754680744676, 1.637578961322106e-14,
            0.8500531768593843, 2.080280392391387e-13,
            0.8523579048289748, -8.604228440844963e-14,
            0.8546688815502315, 8.326672684688674e-17,
            0.8569861239649701, 1.1907141939104804e-14,
            0.85930964906124, 1.6930901125533637e-15,
            0.8616394738731314, -9.2148511043888e-15,
            0.863975615480911, -1.3072876114961218e-14,
            0.8663180910111634, 1.3128387266192476e-14,
            0.8686669176368581, 8.271161533457416e-15,
            0.8710221125775613, -2.7949864644938316e-14,
            0.8733836930995755, -1.4765966227514582e-14,
            0.8757516765159298, -1.532107773982716e-14,
            0.8781260801866573, 1.2378986724570495e-14,
            0.8805069215187851, -1.1213252548714081e-14,
            0.882894217966628, -1.3683498778505054e-14,
            0.8852879870318328, 9.02333763264096e-14,
            0.8876882462632464, -2.3148150063434514e-14,
            0.8900950132574994, -3.449185381754205e-13,
            0.892508305659453, -2.3342439092743916e-14,
            0.894928141160701, 7.494005416219807e-16,
            0.8973545375015584, 7.66053886991358e-15,
            0.8997875124702698, 3.58046925441613e-15,
            0.9022270839033146, 4.3021142204224816e-15,
            0.9046732696855097, -1.0019762797242038e-14,
            0.9071260877502065, 1.1379786002407855e-14,
            0.909585556079292, -1.942890293094024e-14,
            0.912051692703543, 2.5895952049381776e-14,
            0.9145245157024536, 7.827072323607354e-15,
            0.9170040432046723, 1.7208456881689926e-15,
            0.9194902933879413, -8.715250743307479e-15,
            0.9219832844793048, -1.2809198146612744e-14,
            0.9244830347552284, 4.6074255521944e-15,
            0.9269895625416973, 7.008282842946301e-15,
            0.929502886214412, 2.831068712794149e-15,
            0.9320230241988915, -4.690692279041286e-15,
            0.9345499949706023, -2.6145752229922437e-14,
            0.9370838170551372, -1.9609314172441827e-14,
            0.939624509028288, 1.211530875622202e-14,
            0.9421720895162452, 1.1940448629843559e-13,
            0.9447265771954778, 1.2614909117303341e-14,
            0.9472879907934755, -1.1185496973098452e-14,
            0.9498563490882761, -2.3314683517128287e-15,
            0.9524316709088301, -1.0644263248593688e-14,
            0.955013975135192, -4.315992008230296e-15,
            0.9576032806985753, 2.4216739724636227e-15,
            0.9601996065815368, 1.963013085415355e-14,
            0.9628029718180656, 4.73232564246473e-15,
            0.965413395493814, 6.175615574477433e-16,
            0.968030896746145, -3.3861802251067274e-15,
            0.9706554947643162, -5.891120924417237e-15,
            0.9732872087895824, -5.0737192225369654e-14,
            0.9759260581154893, 1.8041124150158794e-16,
            0.978572062087697, -4.649058915617843e-15,
            0.9812252401044642, 7.355227538141662e-16,
            0.9838856116165919, 5.936223734792634e-15,
            0.9865531961276164, -1.1310397063368782e-15,
            0.9892280131939672, -1.2011225347663412e-14,
            0.9919100824251094, -4.683753385137379e-16,
            0.9945994234836228, -1.4982806662011683e-14,
            0.9972960560854724, 3.359725692098081e-15,
            1.0, 0.0,
            1.0027112750502023, -2.671474153004283e-16,
            1.0054299011127916, -1.6067008834497187e-14,
            1.0081558981184178, 3.642919299551295e-16,
            1.010889286051703, 3.507610868425104e-15,
            1.013630084951489, -6.453171330633722e-16,
            1.016378314910954, 1.3426759704060487e-15,
            1.0191339960777215, -2.3311214070176334e-14,
            1.0218971486541109, -8.222589276130066e-15,
            1.0246677928971384, 3.858025010572419e-15,
            1.027445949118777, 1.877664690397296e-14,
            1.030231637686039, -2.8449465006019636e-15,
            1.0330248790212302, 2.4702462297909733e-15,
            1.0358256936019519, -7.313594174718219e-15,
            1.0386341019613787, -8.326672684688674e-17,
            1.0414501246883212, 7.022160630754115e-15,
            1.0442737824274095, -5.946632075648495e-15,
            1.047105095879291, 1.429412144204889e-15,
            1.049944085800694, 9.381384558082573e-15,
            1.052790773004622, -5.953570969552402e-15,
            1.0556451783605751, 2.4577562207639403e-14,
            1.0585073227945059, -9.284240043427872e-15,
            1.0613772272892525, -1.2961853812498703e-14,
            1.0642549128844674, 3.8441472227646045e-15,
            1.067140400676826, 3.1086244689504383e-15,
            1.0700337118202567, 2.0192181260370035e-14,
            1.0729348675259776, 2.6922908347160046e-15,
            1.0758438890627808, -1.3683498778505054e-14,
            1.0787607977571219, 2.761679773755077e-15,
            1.0816856149932175, 3.0253577421035516e-15,
            1.0846183622133163, 9.409140133698202e-15,
            1.087559060917776, 8.534839501805891e-15,
            1.090507732665291, 4.4103609653234344e-14,
            1.0934643990728785, -9.686695889854491e-15,
            1.0964290818163576, -2.5340840537069198e-14,
            1.0994018026302341, 1.5931700403370996e-14,
            1.102382583307852, 1.4460654895742664e-14,
            1.1053714457016148, -1.650068970349139e-13,
            1.1083684117237071, 3.710920459809586e-14,
            1.1113735033448087, -1.1601830607332886e-14,
            1.1143867425958942, 2.1649348980190553e-15,
            1.1174081515673715, 2.9698465908722937e-15,
            1.1204377524096127, 7.799316747991725e-15,
            1.1234755673330008, -2.4397150966137815e-14,
            1.126521618608283, 5.2541304640385533e-14,
            1.1295759285662892, 1.3322676295501878e-15,
            1.1326385195987572, 4.832245714680994e-14,
            1.1357094141578237, 2.3064883336587627e-14,
            1.1387886347566736, -2.2898349882893854e-14,
            1.141876203969568, 8.076872504148014e-15,
            1.1449721444317906, -1.712519015484304e-14,
            1.148076478840192, 1.637578961322106e-14,
            1.1511892299529953, 1.582067810090848e-14,
            1.154310420590267, 6.369904603786836e-14,
            1.1574400736337362, -1.84297022087776e-14,
            1.1605782120274846, -1.762479051592436e-14,
            1.1637248587775864, 1.0963452368173421e-14,
            1.166880036952455, -3.2834845953289005e-14,
            1.170043769683288, 4.654610030740969e-14,
            1.1732160801636253, -1.4654943925052066e-14,
            1.1763969916502701, -1.3683498778505054e-14,
            1.1795865274628723, -4.468647674116255e-15,
            1.182784710984311, -3.658184866139891e-14,
            1.1859915656609776, -1.970645868709653e-14,
            1.1892071150026677, -6.4698246760031e-14,
            1.1924313825823585, -9.591216709736727e-13,
            1.1956643920398005, -3.247402347028583e-14,
            1.1989061670743486, -3.835820550079916e-14,
            1.202156731452726, 2.736699755701011e-14,
            1.2054161090051225, -1.5543122344752192e-15,
            1.2086843236265314, -5.984102102729594e-14,
            1.2119613992768292, 3.3362201889985954e-14,
            1.2152473599804934, 2.90878432451791e-14,
            1.2185422298273916, -1.9872992140790302e-14,
            1.2218460329727474, -1.1934897514720433e-14,
            1.225158793637022, -1.4527268277220173e-13,
            1.2284805361068791, 1.071365218763276e-14,
            1.2318112847341685, 1.0835776720341528e-13,
            1.2351510639369363, 3.497202527569243e-15,
            1.2384998981997986, -2.098321516541546e-14,
            1.241857812073518, 3.941291737419306e-14,
            1.2452248301751068, -1.7513768213461844e-13,
            1.248600977189116, -1.0252909632413321e-13,
            1.2519862778663498, 3.858025010572419e-14,
            1.2553807570247149, 2.731148640577885e-14,
            1.2587844395497014, -1.7208456881689926e-14,
            1.2621973503942812, 3.480549182199866e-14,
            1.2656195145788114, 5.773159728050814e-15,
            1.2690509571917288, -5.051514762044462e-15,
            1.2724917033893919, -1.2323475573339238e-14,
            1.2759417783963776, -1.6431300764452317e-14,
            1.2794012075057224, 5.995204332975845e-14,
            1.282870016078732, -5.1958437552457326e-14,
            1.2863482295460367, 1.2490009027033011e-14,
            1.2898358734066417, -2.6922908347160046e-14,
            1.2933329732290988, 1.0436096431476471e-14,
            1.296839554650994, -1.7319479184152442e-14,
            1.3003556433796573, 7.327471962526033e-15,
            1.3038812651919816, 5.051514762044462e-14,
            1.307416445934654, -2.5646151868841116e-14,
            1.3109612115247846, 2.2315482794965646e-14,
            1.3145155879493446, -1.099120794378905e-14,
            1.3180796012660587, -5.773159728050814e-15,
            1.321653277603327, 1.8496315590255108e-13,
            1.325236643159704, -4.057865155004947e-14,
            1.3288297242058946, -6.48925357893404e-14,
            1.3324325470833205, 1.7219559111936178e-13,
            1.3360451382041798, 3.674838211509268e-14,
            1.3396675240534175, 1.2329026688462363e-13,
            1.3432997311867925, -4.596323321948148e-14,
            1.3469417862329143, -3.3806291099836017e-14,
            1.3505937158922334, 2.1260770921571748e-13,
            1.3542555469368922, -5.551115123125783e-16,
            1.3579273062129547, 5.695444116327053e-14,
            1.3616090206381866, -4.0467629247586956e-14,
            1.3653007172041638, 1.605937605120289e-13,
            1.3690024229745676, -2.4202861936828413e-14,
            1.3727141650876882, 2.0816681711721685e-14,
            1.376435970754569, 4.08006961549745e-14,
            1.3801678672602453, 7.549516567451064e-15,
            1.3839098819638134, -1.9373391779708982e-14,
            1.387662042298513, -1.6708856520608606e-14,
            1.3914243757719233, -2.942091015256665e-15,
            1.3951969099661583, -4.3298697960381105e-14,
            1.3989796725393029, 1.0227374502846942e-12,
            1.4027726912201248, -8.215650382226158e-14,
            1.4065759938190179, 2.4980018054066022e-15,
            1.4103896082172265, -4.524158825347513e-14,
        };
        // 2/pi's bits after the point, 24 at a time (enough for an f64's exponents)
        internal val IPIO2: i32[66] = {
            0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
            0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
            0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
            0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
            0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
            0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
            0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
            0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
            0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
            0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
            0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,
        };
    }
}

// with no OS there's no C math library: the libm names std::math calls are portable's
@attributes([@cfg("os", "none")])
namespace math {
    namespace libm {
        internal fn sqrt(x: f64) -> f64 { return portable::sqrt(x); }
        internal fn cbrt(x: f64) -> f64 { return portable::cbrt(x); }
        internal fn pow(x: f64, y: f64) -> f64 { return portable::pow(x, y); }
        internal fn exp(x: f64) -> f64 { return portable::exp(x); }
        internal fn exp2(x: f64) -> f64 { return portable::exp2(x); }
        internal fn log(x: f64) -> f64 { return portable::log(x); }
        internal fn log2(x: f64) -> f64 { return portable::log2(x); }
        internal fn log10(x: f64) -> f64 { return portable::log10(x); }
        internal fn sin(x: f64) -> f64 { return portable::sin(x); }
        internal fn cos(x: f64) -> f64 { return portable::cos(x); }
        internal fn tan(x: f64) -> f64 { return portable::tan(x); }
        internal fn asin(x: f64) -> f64 { return portable::asin(x); }
        internal fn acos(x: f64) -> f64 { return portable::acos(x); }
        internal fn atan(x: f64) -> f64 { return portable::atan(x); }
        internal fn atan2(y: f64, x: f64) -> f64 { return portable::atan2(y, x); }
        internal fn sinh(x: f64) -> f64 { return portable::sinh(x); }
        internal fn cosh(x: f64) -> f64 { return portable::cosh(x); }
        internal fn tanh(x: f64) -> f64 { return portable::tanh(x); }
        internal fn hypot(x: f64, y: f64) -> f64 { return portable::hypot(x, y); }
        internal fn floor(x: f64) -> f64 { return portable::floor(x); }
        internal fn ceil(x: f64) -> f64 { return portable::ceil(x); }
        internal fn round(x: f64) -> f64 { return portable::round(x); }
        internal fn trunc(x: f64) -> f64 { return portable::trunc(x); }
        internal fn fmod(x: f64, y: f64) -> f64 { return portable::fmod(x, y); }
        internal fn sqrtf(x: f32) -> f32 { return portable::sqrt(x); }
        internal fn cbrtf(x: f32) -> f32 { return portable::cbrt(x); }
        internal fn powf(x: f32, y: f32) -> f32 { return portable::pow(x, y); }
        internal fn expf(x: f32) -> f32 { return portable::exp(x); }
        internal fn exp2f(x: f32) -> f32 { return portable::exp2(x); }
        internal fn logf(x: f32) -> f32 { return portable::log(x); }
        internal fn log2f(x: f32) -> f32 { return portable::log2(x); }
        internal fn log10f(x: f32) -> f32 { return portable::log10(x); }
        internal fn sinf(x: f32) -> f32 { return portable::sin(x); }
        internal fn cosf(x: f32) -> f32 { return portable::cos(x); }
        internal fn tanf(x: f32) -> f32 { return portable::tan(x); }
        internal fn asinf(x: f32) -> f32 { return portable::asin(x); }
        internal fn acosf(x: f32) -> f32 { return portable::acos(x); }
        internal fn atanf(x: f32) -> f32 { return portable::atan(x); }
        internal fn atan2f(y: f32, x: f32) -> f32 { return portable::atan2(y, x); }
        internal fn sinhf(x: f32) -> f32 { return portable::sinh(x); }
        internal fn coshf(x: f32) -> f32 { return portable::cosh(x); }
        internal fn tanhf(x: f32) -> f32 { return portable::tanh(x); }
        internal fn hypotf(x: f32, y: f32) -> f32 { return portable::hypot(x, y); }
        internal fn floorf(x: f32) -> f32 { return portable::floor(x); }
        internal fn ceilf(x: f32) -> f32 { return portable::ceil(x); }
        internal fn roundf(x: f32) -> f32 { return portable::round(x); }
        internal fn truncf(x: f32) -> f32 { return portable::trunc(x); }
        internal fn fmodf(x: f32, y: f32) -> f32 { return portable::fmod(x, y); }
        internal fn fabs(x: f64) -> f64 { return portable::from_bits(portable::bits(x) & 0x7FFFFFFFFFFFFFFF); }
        internal fn fabsf(x: f32) -> f32 { return @cast<f32>(fabs(@cast<f64>(x))); }
    }
}
