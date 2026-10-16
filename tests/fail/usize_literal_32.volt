// flags: --target riscv32-none
// on a 32-bit target usize and isize are 32 bits: a literal past their range is an error
fn wide() -> void {
    val a: usize = 4294967296;
}
fn high() -> void {
    val b: isize = 2147483648;
}
fn low() -> void {
    val c: isize = -2147483649;
}
fn main() -> void {}
// error: 4294967296 doesn't fit in usize (32 bits on this target)
// error: 2147483648 doesn't fit in isize (32 bits on this target)
// error: 2147483649 doesn't fit in isize (32 bits on this target)
