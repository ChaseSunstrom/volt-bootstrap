// derives over enums with payloads: eq, hash and json by variant, through @discriminant and a
// variant's payload as a field (e.KEY, @field(e, "KEY")); a tuple's elements by index
use std::io;

@attributes([@derive(eq, hash, json)])
enum event {
    KEY: u8,
    CLICK: (x: i32, y: i32),
    NAME: std::string,
    QUIT,
}

fn main() -> void {
    val a = event::CLICK(10, 20);
    val b = event::CLICK(10, 20);
    val c = event::CLICK(10, 21);
    val k = event::KEY('a');
    val q = event::QUIT;
    std::println("{} {} {} {} {}", a == b, a == c, a == k, q == event::QUIT, event::QUIT != k);
    std::println("{} {}", a.hash() == b.hash(), a.hash() == c.hash());
    std::println("{} {} {}", @discriminant(a), @discriminant(k), @discriminant(event::QUIT));

    // a variant's payload, as a field
    var e = event::KEY('x');
    std::println("{} {}", e.KEY, @field(e, "KEY"));
    e.KEY = 'y';
    std::println(e);
    std::println("{} {}", a.CLICK.x, @field(a.CLICK, 1));

    var seen: std::map<event, i32> = {};
    seen.put(copy a, 1);
    seen.put(event::NAME(std::string::from("ada")), 2);
    std::println("{} {} {}", *seen.get(copy b), *seen.get(event::NAME(std::string::from("ada"))), seen.get(copy c) == null);

    val all: event[] = { copy k, copy a, event::NAME(std::string::from("ada")), .QUIT };
    for (x&) in all {
        std::println(x.to_json().text());
    }
}
// expect: true false false true true
// expect: true false
// expect: 1 0 3
// expect: 120 120
// expect: KEY(121)
// expect: 10 20
// expect: 1 2 true
// expect: {"KEY":97}
// expect: {"CLICK":[10,20]}
// expect: {"NAME":"ada"}
// expect: "QUIT"
