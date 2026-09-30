// flags: --leak-check
use std::io;
// copy of a map is deep: changing the copy (or what it owns) leaves the original alone

fn main() -> !void {
    var a: std::map<str, std::vec<i32>> = {};
    var xs: std::vec<i32> = {};
    try xs.push(1);
    a.put("one", move xs);
    a.put("two", {});
    var b = copy a;
    try b.get("one")->push(2);
    b.put("three", {});
    val removed = b.remove("two");
    std::println("{} {} {} {}", a.len, b.len, a.get("one")->len, b.get("one")->len);
    std::println("{} {}", a.get("two") != null, b.get("two") == null);
}
// expect: 2 2 1 2
// expect: true true
