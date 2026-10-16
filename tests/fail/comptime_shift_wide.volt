// a shift by the left type's width or more at compile time says so (run time's debug check panics)
comptime fn big(k: u32) -> u64 {
    return 1 << k;
}
fn main() -> u64 {
    return big(64);
}
// error: shift by 64 overflows u64 (64 bits)
