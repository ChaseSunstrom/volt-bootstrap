// Volt calling C++: the use reads counter.hpp (C++, by its extension) with libclang, so Counter (it
// holds a std::string, so it isn't trivially copyable) is a handle to an object C++ allocates, its
// constructor is Counter::new, its destructor runs when the Volt value goes out of scope, and the
// template becomes a generic fn. A Volt type overrides Ticker's virtual tick in an attach block for
// Ticker itself, and Ticker::derive makes the C++ object that calls it. Run: sh run.sh
use std::io;
use { "counter.hpp" } as cpp;

struct shout {
    word: str;
}

attach cpp::tally::Ticker -> shout {
    fn tick(this, self: cpp::tally::Ticker&, n: i32) -> std::string {
        var s = std::string::from(this.word);
        s.append_int(@cast<i64>(n));
        return move s;
    }
}

fn main() -> void {
    var c = cpp::tally::Counter::new(10);
    c.add();
    c.add(5);
    std::println("{} {}", c.value(), cpp::tally::Counter::unit() ?? "");
    std::println("twice: {} {}", cpp::tally::twice<i32>(21), cpp::tally::twice<f64>(1.25));
    val plain = cpp::tally::Ticker::new();
    val s: shout = { word: "HEY" };
    val loud = cpp::tally::Ticker::derive(move s);
    std::println("{} | {}", plain.run(2), loud.run(3));
}
