// @expand takes the one expression it reports on
fn main() -> void {
    val x = @expand(1, 2);
}
// error: @expand takes 1 argument(s)
