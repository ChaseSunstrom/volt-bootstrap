// A literal past i128's maximum is only a u128: with no u128 wanted, or another type wanted, it's
// refused, saying it needs one; a negative literal is still refused for a u128.
use std::io;

fn no_context() -> void {
    std::println("{}", 340282366920938463463374607431768211455);
}

fn as_i128() -> void {
    val x: i128 = 0x80000000000000000000000000000000;
}

fn negative() -> void {
    val y: u128 = -1;
}

fn main() -> void {}
// error: 340282366920938463463374607431768211455 is past i128's maximum: it needs a u128 (annotate it or use @cast<u128>)
// error: 170141183460469231731687303715884105728 is past i128's maximum: it needs a u128 (annotate it or use @cast<u128>)
// error: -1 doesn't fit in u128
