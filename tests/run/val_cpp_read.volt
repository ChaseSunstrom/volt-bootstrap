// a Volt fn passing its reference parameter to a C++ template's const S& or by-value S only reads
// it, so lending it a val is fine; through S& (val_cpp_write) it takes a var, and C++'s write lands
use std::io;
use { "val_cpp_read.hpp" } as cpp;

fn look(s: std::string&) -> i32 {
    return cpp::vr::look(s);
}

fn copied(s: std::string&) -> i32 {
    return cpp::vr::copy_of(s) + cpp::vr::copy_of(copy *s);
}

fn fill(s: std::string&) -> void {
    cpp::vr::fill(s);
}

fn main() -> void {
    val k = std::string::from("hi");
    std::println("{} {} {}", look(&k), copied(&k), k);
    var m = std::string::from("yo");
    fill(&m);
    std::println("{} {}", look(&m), m);
}
// expect: 2 6 hi
// expect: 3 yo!
