// `use std::json;` beside `use std::fmt;`: std::write is still the formatting intrinsic, not json's
// attached write method (which use std::json also makes reachable as std::write)
use std::io;
use std::fmt;
use std::json;

fn main() -> void {
    var s: std::string = {};
    std::write(&s, "{} {}", 1, "a");
    var v = std::json::array();
    v.add(std::json::number(2.0));
    v.write(&s);
    std::println("{}", s.as_str());
}
// expect: 1 a[2]
