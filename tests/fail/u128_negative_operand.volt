// At compile time an untyped negative number beside a u128 is refused, not read as a u128's bits
// (-1 isn't u128's maximum).

comptime fn f() -> u128 {
    val z: u128 = 0;
    val n = -1;
    return z + n;
}

fn g() -> void {
    comptime val x = f();
}

fn main() -> void {}
// error: -1 doesn't fit in u128
