// C++ types with no Volt layout used by value: Volt holds each by handle, makes {} as C++'s T{}
// would, and works their methods out per use (operators by their Volt names: op_call is ())
use std::io;
use { "opaque.hpp" } as cpp;

fn main() -> void {
    var d = cpp::op::make_doc();
    d.set("b", 2);
    std::println("{} {} {}", d.size(), d.get("a"), d.get("zz"));
    var e: cpp::op::json = {};
    e.set("x", 5);
    val f = copy e;
    std::println("{} {}", e.get("x"), f.size());
    val b = cpp::op::boxed(7);
    val b2 = cpp::op::ibox::new(9);
    std::println("{} {}", b.get(), b2.get());
    val add = cpp::op::adder(10);
    std::println("{}", add.op_call(5));
    var t = cpp::op::compute(21);
    std::println("{} {}", t.get(), t.done());
    val n = cpp::op::make_num(4);
    std::println("{} {} {}", n.op_neg().get(), n.op_add(3).get(), n.op_eq(&n));
    std::println("{}", cpp::op::consume(move d));
}
