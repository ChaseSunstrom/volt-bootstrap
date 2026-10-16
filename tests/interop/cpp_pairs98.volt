// a C++98 header's std::map looped over and std::pair results and parameters, read as tuples as
// under C++11 (run under --cc -std=c++98 and -std=c++11, printing the same); and class template
// instances held by handle, and a class's base reached
use std::io;
use { "pairs98.hpp" } as cpp;

fn main() -> void {
    val m = cpp::p98::weights();
    var keys = 0;
    var total = 0.0;
    for (kv) in m {
        keys += kv.0;
        total += kv.1;
    }
    std::println("map {} {}", keys, total);
    val q = cpp::p98::div_mod(17, 5);
    std::println("pair {} {} {}", q.0, q.1, cpp::p98::sum_pair((4, 2)));
    val b = cpp::p98::boxed(5);
    val l = cpp::p98::Labeled::new();
    std::println("box {} {} {} {}", b.get(), cpp::p98::fixed3().size(), l.mark(), l.as_Named().id());
}
