// C++ reference shapes over handle classes: a T* result is a borrowed handle or none, a T* parameter
// takes &h or null, a T& result (and a const T& of a class that can't be copied) borrows the object,
// a unique_ptr hands the object over either way, a shared_ptr's get() borrows, and a base reached
// by two paths has an as_ cast for each
use std::io;
use { "refs.hpp" } as cpp;
fn main() -> void {
    var s: cpp::rf::Shelf = {};
    val w = s.find(2) ?? return;
    std::println("find {} {}", w.id(), s.find(9) == null);
    s.first().bump();
    std::println("first {} last {}", s.first().id(), s.last().id());
    std::println("id_of {} {}", cpp::rf::id_of(&w), cpp::rf::id_of(null));
    val t = s.take() ?? return;
    std::println("take {} {}", t.id(), s.count());
    s.put(t);
    std::println("put {}", s.count());
    val other: cpp::rf::Shelf = {};
    std::println("owned {}", cpp::rf::shelf_size(other));
    val sh = s.share(7);
    val g = sh.get() ?? return;
    std::println("share {}", g.id());
    val d: cpp::rf::D = {};
    std::println("diamond {} {}", d.as_B1_A().a(), d.as_B2_A().a());
}
