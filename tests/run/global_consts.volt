// global initial values of every constant shape: numbers, strings, arrays, structs with padding,
// enum payloads, optionals, error unions, addresses of other globals
use std::io;

struct cfg { name: str; level: u8; limit: i64; ratio: f32; }
enum mode { OFF, ON: i32, NAMED: str, }

val answer: i32 = 42;
val big_one: i128 = -170141183460469231731687303715884105727;
val greeting: str = "hello";
val primes: u16[5] = { 2, 3, 5, 7, 11 };
val base: cfg = { name: "base", level: 3, limit: -9000000000, ratio: 0.5 };
val modes: mode[3] = { mode::OFF, mode::ON(7), mode::NAMED("fast") };
val maybe: cfg? = { name: "maybe", level: 1, limit: 2, ratio: 1.5 };
val nothing: cfg? = null;
var counter: i32 = 0;
val counter_at: i32* = &counter;

fn main() -> void {
    std::println("{} {} {}", answer, big_one, greeting);
    std::println("{} {}", primes[4], primes[0] + primes[1]);
    std::println("{} {} {} {}", base.name, base.level, base.limit, base.ratio);
    for (m&) in modes {
        match (*m) {
            .OFF => { std::println("off"); },
            .ON(n) => { std::println("on {}", n); },
            .NAMED(s) => { std::println("named {}", s); },
        }
    }
    if (maybe) {
        std::println("maybe {} {}", maybe.name, maybe.ratio);
    }
    std::println("nothing {}", nothing == null);
    *counter_at = 5;
    std::println("counter {}", counter);
}
// expect: 42 -170141183460469231731687303715884105727 hello
// expect: 11 5
// expect: base 3 -9000000000 0.5
// expect: off
// expect: on 7
// expect: named fast
// expect: maybe maybe 1.5
// expect: nothing true
// expect: counter 5
