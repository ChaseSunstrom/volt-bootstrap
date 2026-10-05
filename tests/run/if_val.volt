// binding in if and while: if (val v = e) runs its block with e's value when e (an optional or an
// error union) has one; else |err| binds an error union's error; while (val x = e) loops while it does
use std::io;
use std::text;

fn name(k: i32) -> std::string? {
    if (k > 0) {
        return std::string::from("named");
    }
    return null;
}

struct counter {
    n: i32;
}

attach fn next(this: counter&) -> i32? {
    if (this.n >= 5) {
        return null;
    }
    this.n += 1;
    return this.n;
}

// both branches return: the function can't reach its end
fn parsed(s: str) -> i64 {
    if (val n = s.parse_int()) {
        return n;
    } else |e| {
        std::println("{}: {}", s, e);
        return -1;
    }
}

comptime fn first_even(xs: i32[4]) -> i32 {
    for (x) in xs {
        if (val h = half(x)) {
            return h;
        }
    }
    return 0;
}

fn half(x: i32) -> i32? {
    if (x % 2 == 0) {
        return x / 2;
    }
    return null;
}

fn main() -> void {
    // an owned payload moves into the binding
    if (val s = name(1)) {
        std::println("{} {}", s.as_str(), s.len());
    } else {
        std::println("none");
    }
    if (val s = name(0)) {
        std::println("{}", s.as_str());
    } else if (val t = name(2)) {
        std::println("else if {}", t.as_str());
    }
    // no else; var gives a mutable copy
    if (var n = half(10)) {
        n += 1;
        std::println("var {}", n);
    }
    if (val n = half(3)) {
        std::println("not printed {}", n);
    }
    // error unions: else |err|, or a plain else
    std::println("{} {}", parsed("42"), parsed("4x2"));
    if (val n = "7".parse_int()) {
        std::println("seven {}", n);
    } else {
        std::println("no");
    }
    // while: continue and break reach the loop
    var c: counter = { n: 0 };
    while (val i = c.next()) {
        if (i == 2) {
            continue;
        }
        if (i == 4) {
            break;
        }
        std::println("i {}", i);
    }
    // a labeled while, nested ifs with bindings
    var outer: counter = { n: 0 };
    :rows while (val r = outer.next()) {
        var inner: counter = { n: 0 };
        while (val k = inner.next()) {
            if (val h = half(r * k)) {
                if (h > 3) {
                    break :rows;
                }
            }
        }
        std::println("row {}", r);
    }
    // comptime
    comptime val e = first_even({ 3, 5, 8, 9 });
    std::println("comptime {}", e);
}
// expect: named 5
// expect: else if named
// expect: var 6
// expect: 4x2: INVALID
// expect: 42 -1
// expect: seven 7
// expect: i 1
// expect: i 3
// expect: row 1
// expect: comptime 4
