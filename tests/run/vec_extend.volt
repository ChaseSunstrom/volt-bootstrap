// std::vec.extend: all at once for numbers, one copy at a time for owned values, and from the vec's
// own elements (its buffer moves as it grows)
use std::io;
use std::text;
fn main() -> !void {
    var v: std::vec<u8> = {};
    try v.extend("abc");
    try v.extend(v.items());
    try v.extend(v.items()[1..3]);
    var f: std::vec<f64> = {};
    val xs: f64[] = { 1.5, 2.5 };
    try f.extend(xs[..]);
    try f.extend(f.items());
    var s: std::vec<std::string> = {};
    try s.push(std::string::from("x"));
    try s.push(std::string::from("y"));
    try s.extend(s.items());
    var total = 0.0;
    for (x) in f.items() {
        total += x;
    }
    std::println("{} {} {} {}", @cast<str>(v.items()), f.len, total, s.len);
    for (w) in s.items() {
        std::print("{}", w.as_str());
    }
    std::println("");
}
// flags: --leak-check
// expect: abcabcbc 4 8 4
// expect: xyxy
