// flags: --leak-check
use std::io;
use std::string;
// a type that attaches next(this: T&) -> X? loops in for: next until it gives null

struct countdown {
    n: i32;
}

attach fn next(this: countdown&) -> i32? {
    if (this.n == 0) {
        return null;
    }
    this.n -= 1;
    return this.n + 1;
}

fn count_from(n: i32) -> countdown {
    return { n: n };
}

// the words of a text, split on spaces
struct words {
    text: str;
    at: usize = 0;
}

attach fn next(this: words&) -> str? {
    while (this.at < this.text.len && this.text[this.at] == ' ') {
        this.at += 1;
    }
    if (this.at >= this.text.len) {
        return null;
    }
    val start = this.at;
    while (this.at < this.text.len && this.text[this.at] != ' ') {
        this.at += 1;
    }
    return this.text[start..this.at];
}

// the cells of a slice, by reference: next gives a pointer, null when done
struct cells {
    xs: i32[..];
    at: usize = 0;
}

attach fn next(this: cells&) -> i32* {
    if (this.at >= this.xs.len) {
        return null;
    }
    this.at += 1;
    return &this.xs[this.at - 1];
}

// an iterator's state lives in the frame of an async fn, across suspends
async fn sum_slowly() -> i32 {
    var total = 0;
    for (x) in count_from(4) {
        total += x;
        suspend;
    }
    return total;
}

// yields owned strings: each round's is deleted when the round ends (or breaks, or continues)
struct names {
    i: i32;
}

attach fn next(this: names&) -> std::string? {
    if (this.i == 5) {
        return null;
    }
    this.i += 1;
    var s = std::string::from("name-number-");
    s.append_int(this.i);
    return move s;
}

fn main() -> void {
    // a temporary iterator, with the round's index
    for (x, i) in count_from(3) {
        if (i > 0) {
            std::print(" ");
        }
        std::print("{}:{}", x, i);
    }
    std::println("");
    // an iterator in a variable is advanced by the loop: a second loop finds nothing left
    var w: words = { text: "  the quick  fox " };
    for (word) in w {
        std::print("[{}]", word);
    }
    var again = 0;
    for (word) in w {
        again += 1;
    }
    // a val iterator is copied, so it can be looped over again
    val fixed: words = { text: "a b" };
    var seen = 0;
    for (word) in fixed {
        seen += 1;
    }
    for (word) in fixed {
        seen += 1;
    }
    std::println(" {} {}", again, seen);
    // continue, break, a label and an accumulator
    val total = for (x) in count_from(10) [ var acc: i32 = 0 ] {
        if (x % 2 == 0) {
            continue;
        }
        if (x < 4) {
            break;
        }
        acc += x;
    };
    var pairs = 0;
    :outer for (a) in count_from(3) {
        for (b) in count_from(3) {
            if (b == a) {
                continue :outer;
            }
            pairs += 1;
        }
    }
    std::println("{} {}", total, pairs);
    // a pointer iterator binds references: the loop changes the array
    var data: i32[] = { 1, 2, 3 };
    val it: cells = { xs: data[..] };
    for (p) in it {
        *p *= 10;
    }
    std::println("{} {} {}", data[0], data[1], data[2]);
    val f = async sum_slowly();
    for (r) in 0..4 {
        resume f;
    }
    std::println("{}", await f);
    var kept: std::vec<std::string> = {};
    val all: names = { i: 0 };
    for (n, i) in all => n {
        if (i == 1) {
            continue;
        }
        if (i == 3) {
            kept.push(move n) catch @panic("out of memory");
            continue;
        }
        if (i == 4) {
            break;
        }
        std::print("{} ", n.len());
    }
    std::println("{} {}", kept.len, kept.at(0).as_str());
}
// expect: 3:0 2:1 1:2
// expect: [the][quick][fox] 0 4
// expect: 21 3
// expect: 10 20 30
// expect: 10
// expect: 13 13 1 name-number-4
