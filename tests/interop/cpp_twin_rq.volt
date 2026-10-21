// ref-qualified method template pairs: obj.f(&x) calls the reference one, obj.f_value(x) the value one
use std::io;
use { "cpp_twin_rq.hpp" } as cpp;

fn main() -> void {
    var a = cpp::tw::Acc::new(7);
    val g: i32 = 2;
    std::println("cr {} {}", a.cr(&g), a.cr_value(2));
    // && methods take their object: one each
    var y: i32 = 2;
    var b = cpp::tw::Acc::new(2);
    val rr = b.rr(&y);
    std::println("rr {} {}", rr, y);
    var c = cpp::tw::Acc::new(3);
    std::println("rrv {}", c.rr_value(1));
}
// expect: cr 709 809
// expect: rr 500 4
// expect: rrv 604
