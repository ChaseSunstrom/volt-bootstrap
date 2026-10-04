// @discriminant reads an enum's variant
fn main() -> void {
    val x = 3;
    val d = @discriminant(x);
}
// error: @discriminant takes an enum value, found i32
