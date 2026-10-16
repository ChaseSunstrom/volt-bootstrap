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
    // a std::map<std::string, int>'s entries: handles, under C++98 as under C++11
    val nm = cpp::p98::names();
    var names = 0;
    for (kv) in nm {
        names += 1;
    }
    // a move emulated as std::auto_ptr does (T(T&)), passed by value and set into a field
    var o = cpp::p98::Owner::new();
    o.set(6);
    var h = cpp::p98::Holder::new();
    var o2 = cpp::p98::Owner::new();
    o2.set(8);
    h.set_owner(move o2);
    std::println("names {} owner {} {}", names, cpp::p98::take_owner(move o), h.read());
}
