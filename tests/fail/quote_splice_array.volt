// an array can't be spliced: write its elements
comptime fn bad() -> str {
    val xs: i32[2] = { 1, 2 };
    return quote { val y: i32 = $(xs); };
}

@emit(bad());

fn main() -> void {}
// error: can't splice this value into code
