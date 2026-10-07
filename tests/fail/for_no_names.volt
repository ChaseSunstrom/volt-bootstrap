// a for with no names (comptime, as a fuzz mutant had it) is an error, not a crash
fn main() -> void {
    comptime for () in (1, 2) {
    }
}
// error: for takes one or two names
