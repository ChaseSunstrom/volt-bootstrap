// Volt calling Swift: the use names a .swift file, so bolt reads its declarations and builds a
// small shim of @_cdecl functions with swiftc; a struct comes by value, a class as a handle, a
// throwing function as an error. Run: sh run.sh
use std::io;
use { "shapes.swift" } as shapes;

fn main() -> !void {
    val p: shapes::Point = { x: 3.0, y: 4.0 };
    std::println("length {}", p.length());
    val t = shapes::Tally::new();
    t.add(2);
    std::println("tally {}", t.add(5));
    std::println("divide {}", try shapes::divide(7, 2));
    std::println("by zero {}", shapes::divide(1, 0).err);
    val words: str[2] = { "hello", "swift" };
    std::println("{}", shapes::shout(words[..]));
}
