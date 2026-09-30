use std::io;
// a pack can be empty: no C parameter for it
<Args: type...>
fn count(label: str, args: Args...) -> i32 {
    var n = 0;
    comptime for (a) in args {
        n += 1;
    }
    std::println("{} {}", label, n);
    return n;
}
fn main() -> void {
    count("none");
    count("two", 1, "x");
}
// expect: none 0
// expect: two 2
