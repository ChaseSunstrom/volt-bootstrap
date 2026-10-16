// classes Volt used to leave out: an over-aligned one (held by handle, C++'s aligned new making it),
// a class template with a std::mutex field (a generic handle), a class with a protected destructor
// (used through its factory's borrowed handle, freed by its own destroy)
use std::io;
use { "cpp_leftout.hpp" } as cpp;

fn main() -> void {
    var a = cpp::lo::vec8::new();
    a.fill(1.0);
    a.set_tag(7);
    val b = copy a;
    std::println("vec8 {} {} {} {}", a.sum(), b.tag(), a.aligned(), b.aligned());
    var e: cpp::lo::vec8 = {};
    e.fill(0.0);
    std::println("empty {}", e.sum());
    var g: cpp::lo::guarded<i32> = {};
    g.set(41);
    std::println("guarded {} {}", g.get() + 1, g.v());
    {
        val s = cpp::lo::session::create(21) ?? return;
        std::println("session {} {}", s.twice(), s.id());
        cpp::lo::session::destroy(&s);
    }
    std::println("deleted {}", cpp::lo::deleted());
}
