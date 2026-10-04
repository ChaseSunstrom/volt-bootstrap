// @field(v, "name") reads and writes a field named at compile time, and @has_field(T, "name") asks
// whether there is one: with a comptime for over @typeinfo's fields, generic print, eq, hash and
// a JSON writer over any struct are a few lines each
use std::io;

struct point {
    x: i32;
    y: i32;
}

struct maybe {
    o: i32?;
}

struct person {
    name: str;
    age: u32;
    home: point;
}

<T: type>
fn fields_text(v: T&) -> std::string {
    var out = std::string::from(@typeinfo(T).short_name);
    out.append(" {");
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                std::fmt::write(&out, " {}: {};", f.name, @field(v, f.name));
            }
        },
        default => {},
    }
    out.append(" }");
    return move out;
}

<T: type>
fn same(a: T&, b: T&) -> bool {
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                if (@field(a, f.name) != @field(b, f.name)) {
                    return false;
                }
            }
        },
        default => {},
    }
    return true;
}

// FNV-1a over the fields' integers
<T: type>
fn hash_ints(v: T&) -> u64 {
    var h: u64 = 14695981039346656037;
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                h = (h ^ @cast<u64>(@field(v, f.name))) *% 1099511628211;
            }
        },
        default => {},
    }
    return h;
}

// every integer field set to n
<T: type>
fn fill(v: T&, n: i32) -> void {
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                @field(v, f.name) = n;
            }
        },
        default => {},
    }
}

fn main() -> void {
    var p: point = { x: 1, y: 2 };
    val q: point = { x: 1, y: 2 };
    std::println("{} {}", same(&p, &q), hash_ints(&p) == hash_ints(&q));
    fill(&p, 7);
    std::println("{} {} {}", p.x, p.y, same(&p, &q));
    @field(p, "y") += 1;
    std::println("{}", @field(p, "y"));
    val who: person = { name: "ada", age: 36, home: { x: 3, y: 4 } };
    std::println("{}", @field(@field(who, "home"), "x"));
    std::println("{} {} {}", @has_field(person, "age"), @has_field(person, "email"), @has_field(i32, "x"));
    comptime if (@has_field(person, "name")) {
        std::println("named {}", @field(who, "name"));
    }
    std::println("{}", fields_text(&q));
    // it's v.name: narrowed with it, and an assignment through it updates the narrowing
    var m: maybe = { o: 5 };
    if (m.o) {
        std::println("{}", @field(m, "o") + 1);
        @field(m, "o") = 9;
        std::println("{} {}", m.o + 1, &@field(m, "o") == &m.o);
    }
}
// expect: true true
// expect: 7 7 false
// expect: 8
// expect: 3
// expect: true false false
// expect: named ada
// expect: point { x: 1; y: 2; }
// expect: 6
// expect: 10 true
