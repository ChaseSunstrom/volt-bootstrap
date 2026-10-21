// a map C++ made, held by handle, passed back to C++; a Volt std::map to the same function
use std::io;
use { "map_back.hpp" } as cpp;
fn main() -> void {
    val m = cpp::mb::make();
    var v: std::map<std::string, i32> = {};
    v.put(std::string::from("x"), 5);
    std::println("total {} {}", cpp::mb::total(&m), cpp::mb::total(&v));
}
