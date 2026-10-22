// @location() at compile time: in a comptime call's left-out argument, the call's place, as at
// run time
use std::io;

comptime fn where(at: str = @location()) -> str {
    return at;
}

fn main() -> void {
    comptime val c = where();
    val w: str = c;
    var i = w.len;
    while (i > 0 && w[i - 1] != '/' && w[i - 1] != '\\') {
        i -= 1;
    }
    std::println("{}", w[i..w.len]);
}
// expect: location_comptime.volt:10:22
