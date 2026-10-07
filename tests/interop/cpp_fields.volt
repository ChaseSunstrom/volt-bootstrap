// C++ fields and values: a bit-field reads and writes through f() and set_f(v); a std::function
// field takes a closure, which the field keeps (and deletes) for as long as it lives; a namespace
// variable C++ may change is a reference (or, for a string, a copy and set_), and a constant clang
// can't work out is read through a wrapper
use std::io;
use { "fields.hpp" } as cpp;

struct tally {
    n: i32;
}

attach fn delete(this: tally&) -> void {
    std::println("tally {} gone", this.n);
}

fn main() -> void {
    var f: cpp::fl::Flags = { count: 9 };
    f.set_ready(1);
    f.set_level(5);
    std::println("flags {} {} {}", f.ready(), f.level(), f.count);

    var d: cpp::fl::Device = {};
    d.set_on(1);
    d.set_mode(cpp::fl::Mode::Fast);
    std::println("device {} {}", d.on(), d.mode() == cpp::fl::Mode::Fast);
    {
        val t: tally = { n: 3 };
        d.set_scale(|move t| (x: i32) -> i32 { return x * t.n; });
    }
    std::println("scaled {}", d.apply(7));
    d.set_scale(|| (x: i32) -> i32 { return x + 1; });
    std::println("scaled {}", d.apply(7));

    *cpp::fl::counter() = 10;
    std::println("counter {} {}", cpp::fl::next(), *cpp::fl::counter());
    cpp::fl::set_banner("bye");
    std::println("banner {}", cpp::fl::banner());
    cpp::fl::main_device().set_on(1);
    std::println("main {}", cpp::fl::main_device().on());
    std::println("{} {}", cpp::fl::answer(), cpp::fl::motto());
}
