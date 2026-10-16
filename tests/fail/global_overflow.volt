// a global whose value overflows when it's worked out at compile time says so (not that it isn't a
// constant)
val MAX: u128 = 340282366920938463463374607431768211455;
val TWICE: u128 = MAX * 2;
fn main() -> u128 {
    return TWICE;
}
// error: integer overflow
