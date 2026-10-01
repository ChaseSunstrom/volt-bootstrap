// flags: --leak-check
use std::io;
// a string appended to itself (or to a piece of itself) while it has to grow: the text it reads
// from moves with the buffer, and still comes out right

fn main() -> void {
    var s = std::string::from("abcd");  // full: 4 bytes in 4
    s.append(s.as_str());
    s.append(s.as_str()[2..6]);
    s.insert(1, s.as_str()[0..3]);
    std::println("{} {}", s.as_str(), s.len());
}
// expect: aabcbcdabcdcdab 15
