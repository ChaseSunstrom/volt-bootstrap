// a mistyped builtin names the one it's close to
fn main() -> void {
    val n = @sizof(i32);
}
// error: unknown builtin @sizof: did you mean @sizeof?
