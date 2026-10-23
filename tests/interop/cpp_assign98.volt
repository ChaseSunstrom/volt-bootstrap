// cpp_assign98.hpp under C++98 as under C++17: fields of classes that can't be assigned (a const or
// reference member, a member or base with one) get no set_, a class with its own assignment does
use std::io;
use { "cpp_assign98.hpp" } as cpp;
fn main() -> void {
    var b = cpp::as98::Bag::new();
    b.set_n(5);
    val p = b.p();
    std::println("bag {} {}", b.n(), cpp::as98::pin_id(&p));
    var x = 7;
    val r = cpp::as98::Ref::new(&x);
    std::println("ref {}", cpp::as98::ref_value(&r));
}
