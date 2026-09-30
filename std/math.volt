// std::math: constants, the C math library (f64 and f32), and integer arithmetic that reports
// or clamps overflow. With `use std::math;` the names read std::sqrt(x), std::PI.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace math {
    val PI: f64 = 3.141592653589793;       // a circle's circumference over its diameter
    val TAU: f64 = 6.283185307179586;      // 2 pi: a full turn in radians
    val E: f64 = 2.718281828459045;        // the base of natural logarithms
    val SQRT2: f64 = 1.4142135623730951;   // the square root of 2
    val LN2: f64 = 0.6931471805599453;     // the natural logarithm of 2
    val LN10: f64 = 2.302585092994046;     // the natural logarithm of 10
    val EPSILON: f64 = 2.220446049250313e-16; // the gap between 1.0 and the next f64
    val INF: f64 = over_zero(1.0);         // positive infinity (-INF is negative)
    val NAN: f64 = over_zero(0.0);         // not a number: unequal to everything, itself included

    // x / 0.0, at compile time (a global's value is a constant, and a comptime call makes one)
    internal comptime fn over_zero(x: f64) -> f64 {
        return x / 0.0;
    }

    // the C math library (libm, which voltc links): f64 versions
    // the square root
    extern "C" fn sqrt(x: f64) -> f64;
    // the cube root
    extern "C" fn cbrt(x: f64) -> f64;
    // x to the power y
    extern "C" fn pow(x: f64, y: f64) -> f64;
    // e to the power x
    extern "C" fn exp(x: f64) -> f64;
    // 2 to the power x
    extern "C" fn exp2(x: f64) -> f64;
    // the natural logarithm (base e)
    extern "C" fn log(x: f64) -> f64;
    // the base-2 logarithm
    extern "C" fn log2(x: f64) -> f64;
    // the base-10 logarithm
    extern "C" fn log10(x: f64) -> f64;
    // the sine of x radians
    extern "C" fn sin(x: f64) -> f64;
    // the cosine of x radians
    extern "C" fn cos(x: f64) -> f64;
    // the tangent of x radians
    extern "C" fn tan(x: f64) -> f64;
    // the arcsine, in radians
    extern "C" fn asin(x: f64) -> f64;
    // the arccosine, in radians
    extern "C" fn acos(x: f64) -> f64;
    // the arctangent, in radians
    extern "C" fn atan(x: f64) -> f64;
    // the angle of the point (x, y) from the x axis, in radians (-pi to pi)
    extern "C" fn atan2(y: f64, x: f64) -> f64;
    // the hyperbolic sine
    extern "C" fn sinh(x: f64) -> f64;
    // the hyperbolic cosine
    extern "C" fn cosh(x: f64) -> f64;
    // the hyperbolic tangent
    extern "C" fn tanh(x: f64) -> f64;
    // the length of the hypotenuse, sqrt(x*x + y*y) without overflowing
    extern "C" fn hypot(x: f64, y: f64) -> f64;
    // the largest whole number not above x
    extern "C" fn floor(x: f64) -> f64;
    // the smallest whole number not below x
    extern "C" fn ceil(x: f64) -> f64;
    // the nearest whole number, halves away from zero
    extern "C" fn round(x: f64) -> f64;
    // x without its fraction (toward zero)
    extern "C" fn trunc(x: f64) -> f64;
    // the remainder of x / y, with x's sign
    extern "C" fn fmod(x: f64, y: f64) -> f64;

    // f32 versions: libm's sqrtf and friends
    // the square root
    fn sqrt(x: f32) -> f32 { return libm::sqrtf(x); }
    // the cube root
    fn cbrt(x: f32) -> f32 { return libm::cbrtf(x); }
    // x to the power y
    fn pow(x: f32, y: f32) -> f32 { return libm::powf(x, y); }
    // e to the power x
    fn exp(x: f32) -> f32 { return libm::expf(x); }
    // 2 to the power x
    fn exp2(x: f32) -> f32 { return libm::exp2f(x); }
    // the natural logarithm (base e)
    fn log(x: f32) -> f32 { return libm::logf(x); }
    // the base-2 logarithm
    fn log2(x: f32) -> f32 { return libm::log2f(x); }
    // the base-10 logarithm
    fn log10(x: f32) -> f32 { return libm::log10f(x); }
    // the sine of x radians
    fn sin(x: f32) -> f32 { return libm::sinf(x); }
    // the cosine of x radians
    fn cos(x: f32) -> f32 { return libm::cosf(x); }
    // the tangent of x radians
    fn tan(x: f32) -> f32 { return libm::tanf(x); }
    // the arcsine, in radians
    fn asin(x: f32) -> f32 { return libm::asinf(x); }
    // the arccosine, in radians
    fn acos(x: f32) -> f32 { return libm::acosf(x); }
    // the arctangent, in radians
    fn atan(x: f32) -> f32 { return libm::atanf(x); }
    // the angle of the point (x, y) from the x axis, in radians (-pi to pi)
    fn atan2(y: f32, x: f32) -> f32 { return libm::atan2f(y, x); }
    // the hyperbolic sine
    fn sinh(x: f32) -> f32 { return libm::sinhf(x); }
    // the hyperbolic cosine
    fn cosh(x: f32) -> f32 { return libm::coshf(x); }
    // the hyperbolic tangent
    fn tanh(x: f32) -> f32 { return libm::tanhf(x); }
    // the length of the hypotenuse, sqrt(x*x + y*y) without overflowing
    fn hypot(x: f32, y: f32) -> f32 { return libm::hypotf(x, y); }
    // the largest whole number not above x
    fn floor(x: f32) -> f32 { return libm::floorf(x); }
    // the smallest whole number not below x
    fn ceil(x: f32) -> f32 { return libm::ceilf(x); }
    // the nearest whole number, halves away from zero
    fn round(x: f32) -> f32 { return libm::roundf(x); }
    // x without its fraction (toward zero)
    fn trunc(x: f32) -> f32 { return libm::truncf(x); }
    // the remainder of x / y, with x's sign
    fn fmod(x: f32, y: f32) -> f32 { return libm::fmodf(x, y); }

    namespace libm {
        internal extern "C" fn sqrtf(x: f32) -> f32;
        internal extern "C" fn cbrtf(x: f32) -> f32;
        internal extern "C" fn powf(x: f32, y: f32) -> f32;
        internal extern "C" fn expf(x: f32) -> f32;
        internal extern "C" fn exp2f(x: f32) -> f32;
        internal extern "C" fn logf(x: f32) -> f32;
        internal extern "C" fn log2f(x: f32) -> f32;
        internal extern "C" fn log10f(x: f32) -> f32;
        internal extern "C" fn sinf(x: f32) -> f32;
        internal extern "C" fn cosf(x: f32) -> f32;
        internal extern "C" fn tanf(x: f32) -> f32;
        internal extern "C" fn asinf(x: f32) -> f32;
        internal extern "C" fn acosf(x: f32) -> f32;
        internal extern "C" fn atanf(x: f32) -> f32;
        internal extern "C" fn atan2f(y: f32, x: f32) -> f32;
        internal extern "C" fn sinhf(x: f32) -> f32;
        internal extern "C" fn coshf(x: f32) -> f32;
        internal extern "C" fn tanhf(x: f32) -> f32;
        internal extern "C" fn hypotf(x: f32, y: f32) -> f32;
        internal extern "C" fn floorf(x: f32) -> f32;
        internal extern "C" fn ceilf(x: f32) -> f32;
        internal extern "C" fn roundf(x: f32) -> f32;
        internal extern "C" fn truncf(x: f32) -> f32;
        internal extern "C" fn fmodf(x: f32, y: f32) -> f32;
        internal extern "C" fn fabs(x: f64) -> f64;
        internal extern "C" fn fabsf(x: f32) -> f32;
    }

    // whether x is NaN (the only value unequal to itself)
    <T: type>
    fn is_nan(x: T) -> bool {
        return x != x;
    }

    // whether x is a number that isn't infinite or NaN (true for every integer)
    <T: type>
    fn is_finite(x: T) -> bool {
        return x - x == x - x; // NaN for infinity and NaN, 0 otherwise
    }

    // whether x is positive or negative infinity
    <T: type>
    fn is_inf(x: T) -> bool {
        return !is_finite(x) && !is_nan(x);
    }

    // x without its sign (for the most negative integer, that overflows)
    <T: type>
    fn abs(x: T) -> T {
        val zero: T = 0;
        if (x < zero) {
            return zero - x;
        }
        return x;
    }
    // x without its sign (-0.0 gives 0.0)
    fn abs(x: f64) -> f64 { return libm::fabs(x); }
    // x without its sign (-0.0 gives 0.0)
    fn abs(x: f32) -> f32 { return libm::fabsf(x); }

    // the smaller of a and b by < (a when neither is smaller)
    <T: type>
    fn min(a: T, b: T) -> T {
        if (b < a) {
            return b;
        }
        return a;
    }

    // the larger of a and b by < (a when neither is larger)
    <T: type>
    fn max(a: T, b: T) -> T {
        if (a < b) {
            return b;
        }
        return a;
    }

    // x, moved into lo..=hi
    <T: type>
    fn clamp(x: T, lo: T, hi: T) -> T {
        if (x < lo) {
            return lo;
        }
        if (hi < x) {
            return hi;
        }
        return x;
    }

    // whether integer type T is signed
    <T: type>
    internal fn signed() -> bool {
        val zero: T = 0;
        return zero -% 1 < zero;
    }

    // a + b, or null when it doesn't fit in T
    <T: type>
    fn checked_add(a: T, b: T) -> T? {
        val zero: T = 0;
        val r = a +% b;
        // adding a non-negative b can only wrap below a, a negative one only above it
        if ((b < zero) != (r < a)) {
            return null;
        }
        return r;
    }

    // a - b, or null when it doesn't fit in T
    <T: type>
    fn checked_sub(a: T, b: T) -> T? {
        val zero: T = 0;
        val r = a -% b;
        // subtracting a non-negative b can only wrap above a, a negative one only below it
        if ((b < zero) != (r > a)) {
            return null;
        }
        return r;
    }

    // a * b, or null when it doesn't fit in T
    <T: type>
    fn checked_mul(a: T, b: T) -> T? {
        val zero: T = 0;
        if (a == zero || b == zero) {
            return zero;
        }
        if (signed<T>()) {
            // the one product that dividing back can't check: it would divide MIN by -1
            val neg_one: T = zero -% 1;
            val lo = T::min_value();
            if ((a == neg_one && b == lo) || (b == neg_one && a == lo)) {
                return null;
            }
        }
        val r = a *% b;
        if (r / b != a) {
            return null;
        }
        return r;
    }

    // a / b, or null when b is 0 or the quotient doesn't fit (MIN / -1)
    <T: type>
    fn checked_div(a: T, b: T) -> T? {
        val zero: T = 0;
        if (b == zero) {
            return null;
        }
        if (signed<T>() && b == zero -% 1 && a == T::min_value()) {
            return null;
        }
        return a / b;
    }

    // a + b, or T's largest or smallest value when it doesn't fit
    <T: type>
    fn saturating_add(a: T, b: T) -> T {
        val zero: T = 0;
        val r = checked_add(a, b);
        if (r) {
            return r;
        }
        if (b < zero) {
            return T::min_value();
        }
        return T::max_value();
    }

    // a - b, or T's largest or smallest value when it doesn't fit
    <T: type>
    fn saturating_sub(a: T, b: T) -> T {
        val zero: T = 0;
        val r = checked_sub(a, b);
        if (r) {
            return r;
        }
        if (b > zero) {
            return T::min_value();
        }
        return T::max_value();
    }

    // a * b, or T's largest or smallest value when it doesn't fit
    <T: type>
    fn saturating_mul(a: T, b: T) -> T {
        val zero: T = 0;
        val r = checked_mul(a, b);
        if (r) {
            return r;
        }
        if ((a < zero) != (b < zero)) {
            return T::min_value();
        }
        return T::max_value();
    }

    // the greatest common divisor of a and b, never negative (gcd(0, 0) is 0)
    <T: type>
    fn gcd(a: T, b: T) -> T {
        val zero: T = 0;
        var x = abs(a);
        var y = abs(b);
        while (y != zero) {
            val t = x % y;
            x = y;
            y = t;
        }
        return x;
    }

    // the least common multiple of a and b, never negative (0 when either is 0)
    <T: type>
    fn lcm(a: T, b: T) -> T {
        val zero: T = 0;
        if (a == zero || b == zero) {
            return zero;
        }
        return abs(a / gcd(a, b) * b);
    }
}

// the largest value of integer type T: i32::max_value()
<T: type>
attach fn max_value(static this: T) -> T {
    val zero: T = 0;
    val one: T = 1;
    if (std::math::signed<T>()) {
        // 2^(bits-2) twice, less one: 2^(bits-1) - 1 without shifting into the sign bit
        val half = one << (@sizeof(T) * 8 - 2);
        return half - one + half;
    }
    return zero -% one;
}

// the smallest value of integer type T: i32::min_value()
<T: type>
attach fn min_value(static this: T) -> T {
    val zero: T = 0;
    if (std::math::signed<T>()) {
        return zero - T::max_value() - 1;
    }
    return zero;
}
