// Volt calling C++: the use reads counter.hpp (C++, by its extension) with libclang, so Counter is
// a Volt struct with C++'s layout, its constructor is Counter::new, its destructor runs when the
// Volt value goes out of scope, and the template becomes a generic fn. Run: sh run.sh
use std::io;
use { "counter.hpp" } as cpp;

fn main() -> void {
    var c = cpp::tally::Counter::new(10);
    c.add();
    c.add(5);
    std::println("{} {}", c.value(), cpp::tally::Counter::unit() ?? "");
    std::println("twice: {} {}", cpp::tally::twice<i32>(21), cpp::tally::twice<f64>(1.25));
}
