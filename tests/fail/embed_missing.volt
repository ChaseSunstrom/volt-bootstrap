// @embed reads a file next to the source: one that isn't there is an error naming it

fn main() -> void {
    val text = @embed("no_such_file.txt");
}
// error: @embed can't read
// error: no_such_file.txt
