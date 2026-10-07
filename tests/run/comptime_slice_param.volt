// a comptime fn's slice parameter takes an array argument (a literal list), as a runtime fn's does
use std::io;

comptime fn count(names: str[..]) -> usize {
    return names.len;
}

comptime fn named(names: str[..]) -> type {
    return enum {
        comptime for (n) in names {
            (n),
        }
    };
}

type color = named({ "red", "green", "blue" });

fn main() -> void {
    val n: usize = count({ "a", "b", "c" });
    std::println("{} {}", n, @typeinfo(color).variants.len);
}
// expect: 3 3
