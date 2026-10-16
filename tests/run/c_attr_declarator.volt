use std::io;
// a function pointer parameter whose declarator starts with an attribute, as MinGW's stdlib.h spells
// qsort's comparison function (int (__cdecl *cmp)(...)), is a nested declarator, not a parameter list
use { "c_attr_declarator.h" } as c;
extern "C" fn by_value(a: void*, b: void*) -> i32 {
    return *@cast<i32*>(a) - *@cast<i32*>(b);
}
fn main() -> void {
    var xs: i32[5] = { 5, 3, 9, 1, 4 };
    c::qsort(@cast<void*>(&xs[0]), 5, 4, by_value);
    std::println("{} {} {} {} {}", xs[0], xs[1], xs[2], xs[3], xs[4]);
}
// expect: 1 3 4 5 9
