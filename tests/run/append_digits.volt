// std's string writes a number's digits with no bounds checks (a u64 has at most 20 digits, and the
// room for them is reserved first): every width, the extremes, and appending at full capacity
// flags: --release
use std::io;

fn main() -> void {
    var s: std::string = {};
    s.append_uint(0);
    s.push(' ');
    s.append_uint(9);
    s.push(' ');
    s.append_uint(10);
    s.push(' ');
    s.append_uint(18446744073709551615);
    s.push(' ');
    s.append_int(-9223372036854775807 - 1);
    std::println("{}", s.as_str());
    // each append lands exactly at the end, growing the string as it goes
    var t: std::string = {};
    var p: u64 = 1;
    for (i) in 0..20 {
        t.append_uint(p);
        p = p *% 10;
    }
    std::println("{} {}", t.len(), t.as_str()[t.len() - 20..t.len()]);
}
// expect: 0 9 10 18446744073709551615 -9223372036854775808
// expect: 210 10000000000000000000
