// What a library adds to namespace std: its std::hash<Key> keys a std::unordered_map of its Key,
// and its swap, found by argument-dependent lookup, runs from @cpp
use std::io;
// (the map comes from the use that names the header declaring the hash: an instance sees its own
// use's headers, as a C++ file sees what it includes)
use cpp { "unordered_map", "special.hpp" } as cpp;

fn main() -> void {
    var m: cpp::stdcxx::unordered_map<cpp::sp::Key, i32> = {};
    val a: cpp::sp::Key = { id: 3 };
    m.insert_or_assign(a, 30);
    val b: cpp::sp::Key = { id: 4 };
    m.insert_or_assign(b, 40);
    std::println("{} {}", m.size(), *m.at(a));
    var x: cpp::sp::Key = { id: 1 };
    var y: cpp::sp::Key = { id: 2 };
    @cpp<void>("swap({0}, {1})", &x, &y);
    std::println("{} {}", x.id, y.id);
}
