// Volt fns attached to types from other languages: a C struct and two C++ classes, one laid out by
// Volt and one held by handle. Comptime code reads the C struct's fields like any Volt struct's
use std::io;
use { "reading.h" } as c;
use { "bank.hpp" } as cpp;

attach fn fahrenheit(this: c::reading&) -> f64 {
    return this.celsius * 9.0 / 5.0 + 32.0;
}

attach fn dollars(this: cpp::bank::money&) -> f64 {
    return @cast<f64>(this.cents) / 100.0;
}

attach fn statement(this: cpp::bank::account&) -> std::string {
    return std::fmt::format("{}: {} cents", this.owner(), this.balance());
}

// every field of any struct, C's included
<T: type>
fn fields_of(v: T&) -> std::string {
    var out = std::string::from(@typeinfo(T).short_name);
    comptime for (f) in @typeinfo(T).fields {
        std::fmt::write(&out, " {}={}", f.name, @field(v, f.name));
    }
    return out;
}

fn main() -> void {
    val r: c::reading = { sensor: 3, celsius: 21.5 };
    std::println("{} {}", r.fahrenheit(), fields_of(&r));
    val m: cpp::bank::money = { cents: 1250 };
    std::println("{}", m.dollars());
    var a = cpp::bank::account::new("ada");
    a.deposit(500);
    std::println("{}", a.statement());
}
