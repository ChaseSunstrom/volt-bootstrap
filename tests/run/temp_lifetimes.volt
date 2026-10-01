// flags: --leak-check
use std::io;
use std::string;
use std::text;
// a temporary lives to the end of its statement, and one in a val's initializer to the end of the
// val's scope, so a view into it (word(n).as_str()) stays valid while it's used; early exits
// (?? return, ?? continue, break) delete it too, a while condition deletes its own each test, a
// break's value keeps its temporary for the val it goes to, and a defer's statement keeps its own

fn s(text: str) -> std::string {
    return std::string::from(text);
}

// long enough to be on the heap, so freed bytes get reused (and poisoned in debug builds)
fn word(n: i32) -> std::string {
    var out = s("word-");
    out.append_int(n);
    out.append("-padding-to-reach-the-heap");
    return move out;
}

fn first_char(t: str) -> u8 {
    return t[0];
}

fn find_nine(n: i32) -> usize? {
    val at = word(n).as_str().find("9") ?? return null;
    return at;
}

async fn later(n: i32) -> usize {
    var total: usize = 0;
    total += word(n).as_str().len;
    suspend;
    total += word(n + 1).as_str().len;
    return total;
}

fn main() -> void {
    defer std::println("defer {}", word(11).as_str());
    var g = s("");
    g.append(word(1).as_str());
    g.push(' ');
    g.append(word(2).as_str());
    std::println("{}", g.as_str());
    std::println("{} {}", word(3).as_str(), first_char(word(4).as_str()));
    if (word(5).as_str().starts_with("word-5")) {
        std::println("if ok");
    }
    val kept = word(6).as_str();
    var x = s("tail");
    std::println("{} {}", kept, x.as_str());
    // a break's value carries its temporary out to the val
    val carried = :b {
        break :b word(10).as_str();
    };
    std::println("{}", carried);
    var i = 0;
    while (word(i).as_str().len > 0 && i < 3) {
        i += 1;
    }
    std::println("{}", i);
    for (k) in 0..3 {
        if (word(k).as_str().len > 0 && k == 0) {
            continue;
        }
        val at = word(k).as_str().find("2") ?? continue;
        std::println("loop {} {}", k, at);
        break;
    }
    std::println("{} {}", find_nine(19), find_nine(1));
    val h = async later(7);
    resume h;
    std::println("{}", await h);
}
// expect: word-1-padding-to-reach-the-heap word-2-padding-to-reach-the-heap
// expect: word-3-padding-to-reach-the-heap 119
// expect: if ok
// expect: word-6-padding-to-reach-the-heap tail
// expect: word-10-padding-to-reach-the-heap
// expect: 3
// expect: loop 2 5
// expect: 6 null
// expect: 64
// expect: defer word-11-padding-to-reach-the-heap
