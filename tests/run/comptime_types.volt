// types built at compile time: struct { } and enum { } are values of type type. comptime for and
// comptime if run in their bodies, and a name that isn't a bare identifier is worked out (its str
// value). A comptime fn that returns a type gives the same type for the same arguments, named
// after the call; `type name = struct { ... };` names one written right there
use std::io;

struct particle {
    x: f32;
    y: f32;
    alive: bool;
}

// one vector per field of T
comptime fn soa(T: type) -> type {
    return struct {
        comptime for (f) in @typeinfo(T).fields {
            f.name: std::vec<f.field_type> = {};
        }
    };
}

// NAME = base + i for each name
comptime fn codes(names: str[3], base: i32) -> type {
    return enum {
        comptime for (i) in 0..3 {
            names[i] = base + i,
        }
    };
}

// a member only when asked for, and a name put together with str + str
comptime fn counter(named: str, with_max: bool) -> type {
    return struct {
        (named + "_count"): i32 = 0;
        comptime if (with_max) {
            max: i32 = 100;
        }
    };
}

// a body held in a comptime val, then returned
comptime fn pair_of(T: type) -> type {
    val S = struct {
        first: T;
        second: T;
    };
    return S;
}

// an enum with a backing type and payloads, a variant chosen by comptime if / else
comptime fn shape(with_circle: bool) -> type {
    return enum: u8 {
        SQUARE: f64,
        comptime if (with_circle) {
            CIRCLE: f64,
        } else {
            NONE,
        }
    };
}

fn area(s: shape(true)) -> f64 {
    match (s) {
        .SQUARE(w) => { return w * w; },
        .CIRCLE(r) => { return 3.0 * r * r; },
    }
}

// the index as a second name, and defaults worked out from it (negative and float ones too); each
// field optional, its type written as the other field's
comptime fn numbered(names: str[3]) -> type {
    return struct {
        comptime for (n, i) in names {
            (n): i64 = @cast<i64>(i) - 1;
            (n + "_w"): f64 = 0.5 * @cast<f64>(i);
        }
    };
}

comptime fn maybe(T: type) -> type {
    return struct {
        comptime for (f) in @typeinfo(T).fields {
            f.name: f.field_type? = null;
        }
    };
}

// else if chains in a body
comptime fn sized(k: i32) -> type {
    return struct {
        comptime if (k == 0) {
            zero: i32 = 0;
        } else if (k == 1) {
            one: i32 = 1;
        } else {
            many: i32 = 2;
        }
    };
}

// a type built inside another comptime fn and passed on: each argument its own type, even though
// the inner one keeps the name of where it is
comptime fn wrap(X: type) -> type {
    return struct {
        inner: X;
    };
}

comptime fn boxed(T: type) -> type {
    val S = struct {
        v: T;
    };
    return wrap(S);
}

type color = enum {
    RED,
    GREEN,
};

type status = codes({ "OK", "MOVED", "GONE" }, 200);

type point3 = struct {
    x: f64;
    y: f64;
    z: f64 = 1.5;
};

// soa(particle) here is the same type as main's
attach fn count(this: soa(particle)&) -> usize {
    return this.x.len;
}

fn main() -> void {
    var ps: soa(particle) = {};
    ps.x.push(1.0);
    ps.y.push(2.5);
    ps.alive.push(true);
    std::println("{} {} {}", ps.count(), *ps.y.at(0), @typeinfo(soa(particle)).short_name);
    std::println("{} {}", status::GONE as i32, status::OK as i32);
    val c: counter("hits", true) = {};
    val d: counter("hits", false) = {};
    std::println("{} {} {} {}", c.hits_count, c.max, @has_field(@typeof(c), "max"), @has_field(@typeof(d), "max"));
    val p: point3 = { x: 1.0, y: 2.0 };
    std::println("{} {}", p.z, @typeinfo(point3).short_name);
    val two: pair_of(i32) = { first: 1, second: 2 };
    std::println("{} {} {} {}", two.first + two.second, area(.CIRCLE(1.0)), @typeinfo(pair_of(i32)).short_name, @has_field(shape(false), "x"));
    val nums: numbered({ "a", "b", "c" }) = {};
    std::println("{} {} {} {}", nums.a, nums.c, nums.c_w, @typeinfo(color).short_name);
    var m: maybe(particle) = {};
    m.y = 2.5;
    val k: sized(1) = {};
    std::println("{} {} {} {}", m.x == null, m.y ?? 0.0, k.one, @has_field(sized(5), "many"));
    val bi: boxed(i32) = { inner: { v: 1 } };
    val bf: boxed(f64) = { inner: { v: 2.5 } };
    std::println("{} {}", bi.inner.v, bf.inner.v);
}
// expect: 1 2.5 soa(particle)
// expect: 202 200
// expect: 0 100 true false
// expect: 1.5 point3
// expect: 3 3 pair_of(i32) false
// expect: -1 1 1 color
// expect: true 2.5 1 true
// expect: 1 2.5
