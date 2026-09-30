// flags: --leak-check
// .value, .none and .err see through a reference, like struct fields do
use std::io;

error oops {
    MSG: std::string,
}

fn main() -> i32 {
    var results: std::vec<oops!i32> = {};
    results.push(oops::MSG(std::string::from("long enough to allocate a buffer"))) catch @panic("oom");
    results.push(7) catch @panic("oom");
    var names: std::vec<std::string?> = {};
    names.push(null) catch @panic("oom");
    names.push(std::string::from("ada")) catch @panic("oom");
    val first = results.at(0);
    std::println("{} {} {}", results.at(0).err != null, results.at(1).value, first.err == null);
    std::println("{} {}", names.at(0).none, names.at(1).value);
    return 0;
}
// expect: true 7 false
// expect: true ada
