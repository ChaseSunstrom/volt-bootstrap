// get_or_put(key, value): the value for key, put there first when the key is new, so counting is
// one line; a key already there keeps its value (the one given is dropped)
use std::io;

fn main() -> void {
    var m: std::map<str, i32> = {};
    var s: std::sorted_map<str, i32> = {};
    for (w) in "b a b c b a".words().items() {
        *m.get_or_put(w, 0) += 1;
        *s.get_or_put(w, 0) += 1;
    }
    std::println("{} {} {} {}", *(m.get("a") ?? return), *(m.get("b") ?? return), *(m.get("c") ?? return), m.len);
    for (e) in s.iter() {
        std::println("{} {}", *e.key, *e.value);
    }
    var names: std::map<i32, std::string> = {};
    names.put(1, std::string::from("one"));
    std::println("{} {}", *names.get_or_put(1, std::string::from("uno")), *names.get_or_put(2, std::string::from("two")));
}
// expect: 2 3 1 3
// expect: a 2
// expect: b 3
// expect: c 1
// expect: one two
