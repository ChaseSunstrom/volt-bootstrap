// only shifts take an operand of another type at compile time: + keeps both sides one type
comptime fn add(a: u32, b: u64) -> u64 {
    return a + b;
}
fn main() -> u64 {
    return add(1, 2);
}
// error: mismatched
