// flags: --pkg hidden=tests/pkgs/hidden
use std::io;
// internal items are fine inside their own package: the program's here, and std's own (vec, map
// and json use std's internal helpers when they're instantiated from this program; hidden uses its
// own at compile time)

internal struct secret { n: i32; }
internal val BASE: i32 = 40;
internal fn bump(s: secret) -> i32 { return s.n + BASE; }

fn main() -> !void {
    val s: secret = { n: 2 };
    var m: std::map<i32, i32> = {};
    m.put(1, bump(s));
    var v: std::vec<i32> = {};
    try v.push(*(m.get(1) ?? return));
    val j = try std::json::parse("[1, \"x\"]");
    std::println("{} {} {}", *v.at(0), j.len(), j.at(1).as_str() ?? "?");
    std::println("{} {}", hidden::limit(), hidden::doubled());
}
// expect: 42 2 x
// expect: 6 6
