use std::io;
// resize fills with copies (strings too: each one its own) and shrinks by deleting

fn main() -> !void {
    var xs: std::vec<u8> = {};
    try xs.resize(5, 7);
    try xs.resize(3, 0);
    try xs.resize(4, 9);
    std::println("{} {} {} {}", xs.len, *xs.at(0), *xs.at(2), *xs.at(3));
    var ss: std::vec<std::string> = {};
    try ss.resize(2, std::string::from("ab"));
    ss.at(0).push('c');
    try ss.resize(1, std::string::from(""));
    try ss.resize(3, std::string::from("z"));
    std::println("{} {} {} {}", ss.len, *ss.at(0), *ss.at(1), *ss.at(2));
}
// expect: 4 7 7 9
// expect: 3 abc z z
