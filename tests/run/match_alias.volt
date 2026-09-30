use std::io;

// a by-reference binding (x&) is a T& to the payload in the matched place: it stays valid after the
// match. A plain binding is a copy taken when the arm starts, so reassigning the matched place in
// the arm doesn't change it
struct big {
    name: str;
    nums: i32[4];
}

enum item {
    BIG: big,
    SMALL: i32,
}

fn big_of(it: item&) -> big* {
    match (*it) {
        .BIG(b&) => { return b; },
        default => { return null; },
    }
}

fn main() -> void {
    var items: item[2] = { item::SMALL(1), item::BIG({ name: "b", nums: { 1, 2, 3, 4 } }) };
    val none = big_of(&items[0]);
    std::println("none {}", none == null);
    val p = big_of(&items[1]) ?? return;
    std::println("{} {}", p.name, p.nums[3]);
    // the reference points into items[1] itself
    items[1] = item::BIG({ name: "c", nums: { 9, 8, 7, 6 } });
    std::println("{} {}", p.name, p.nums[0]);
    // a state machine: the arm replaces the state, then still reads the old payload
    var st = state::COUNT(1);
    for (i) in 0..3 {
        match (st) {
            .COUNT(n) => {
                st = state::COUNT(n * 10);
                if (n >= 100) {
                    st = state::DONE("big");
                }
                std::println("was {}", n);
            },
            .DONE(why) => { std::println("done {}", why); },
        }
    }
}

enum state {
    COUNT: i32,
    DONE: str,
}
// expect: none true
// expect: b 4
// expect: c 9
// expect: was 1
// expect: was 10
// expect: was 100
