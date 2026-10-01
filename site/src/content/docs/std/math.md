---
title: Math
description: Constants, the C math library in f64 and f32, min/max/clamp, integer limits, and checked and saturating arithmetic.
sidebar:
  order: 3
---

`std::math` is the C math library plus the integer arithmetic C leaves out. With `use std::math;`
its names read `std::sqrt(x)`, `std::PI`.

```volt
use std::io;
use std::math;

fn main() -> void {
    val angle = std::PI / 6.0;
    val side: f32 = 9.0;
    std::println("{:.3} {:.3} {} {}", std::sin(angle), std::hypot(3.0, 4.0), std::sqrt(side), std::round(-2.5));
    std::println("{} {} {}", std::clamp(140, 0, 100), std::max(2.5, -1.0), std::gcd(84, 36));
    std::println("{} {} {}", std::is_nan(std::NAN), std::INF > 1e308, std::abs(-7));
}
// expect: 0.500 5.000 3 -3
// expect: 100 2.5 12
// expect: true true 7
```

## Floats

| | |
| --- | --- |
| constants | `PI`, `TAU`, `E`, `SQRT2`, `LN2`, `LN10`, `EPSILON`, `INF`, `NAN` (all `f64`) |
| powers and logs | `sqrt`, `cbrt`, `pow`, `exp`, `exp2`, `log` (natural), `log2`, `log10` |
| trigonometry | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2(y, x)`, `sinh`, `cosh`, `tanh`, `hypot` |
| rounding | `floor`, `ceil`, `round` (halves away from zero), `trunc`, `fmod` |
| classes | `is_nan`, `is_inf`, `is_finite` |

Each function takes and returns an `f64`, and has an `f32` overload that stays in `f32` (libm's
`sqrtf` and friends). Angles are in radians.

## Any number

`abs`, `min`, `max` and `clamp(x, lo, hi)` work on integers and floats alike, comparing with `<`.

## Integers

`T::max_value()` and `T::min_value()` are an integer type's limits (`i8::min_value()` is -128,
`u64::max_value()` is 18446744073709551615).

Plain `+`, `-` and `*` trap on overflow in debug builds and wrap in `--release`; `+%`, `-%` and `*%`
always wrap. When overflow is an expected case rather than a bug, say what should happen:

```volt
use std::io;
use std::math;

fn main() -> void {
    val stock: u8 = 250;
    val order: u8 = 10;
    val have = std::checked_add(stock, order) ?? u8::max_value();
    std::println("{} {} {}", std::checked_add(stock, order), have, std::saturating_sub(order, stock));
    std::println("{} {}", std::checked_div(10, 0), std::checked_mul(i32::min_value(), -1));
}
// expect: null 255 0
// expect: null null
```

- `checked_add`, `checked_sub`, `checked_mul`, `checked_div` return `null` when the result doesn't
  fit (or on division by zero).
- `saturating_add`, `saturating_sub`, `saturating_mul` stop at the type's largest or smallest value.
- `gcd` and `lcm` are never negative; `gcd(0, 0)` and `lcm(0, x)` are 0. Like `abs`, they overflow
  when the answer doesn't fit in the type: `gcd(i32::min_value(), 0)` is 2147483648.
