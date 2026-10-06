// fns and attach fns a comptime fn declares when it runs: their bodies see its compile-time locals
// (parameters, the types it built, loop variables), their names can be worked out, and a type's
// methods come with it once however often the call runs
use std::io;

// one vector per field of T
comptime fn soa(T: type) -> type {
    val S = struct {
        comptime for (f) in @typeinfo(T).fields {
            f.name: std::vec<f.field_type> = {};
        }
    };
    attach fn push(this: S&, v: T) -> void {
        comptime for (f) in @typeinfo(T).fields {
            @field(this, f.name).push(@field(v, f.name));
        }
    }
    attach fn len(this: S&) -> usize {
        comptime for (f) in @typeinfo(T).fields {
            return @field(this, f.name).len;
        }
        return 0;
    }
    return S;
}

struct particle {
    x: f32;
    y: f32;
    alive: bool;
}

// NAME = base + i for each name, and a lookup by text
comptime fn codes(names: str[], base: i32) -> type {
    val E = enum {
        comptime for (i) in 0..names.len {
            names[i] = base + @cast<i32>(i),
        }
    };
    attach fn parse(static this: E, text: str) -> E? {
        comptime for (v) in @typeinfo(E).variants {
            if (text == v.name) {
                return @field(E, v.name);
            }
        }
        return null;
    }
    return E;
}

type status = codes({ "OK", "MOVED", "GONE" }, 200);

// get_x(), get_y(): one getter per field, named after it
comptime fn getters(T: type) -> void {
    for (f) in @typeinfo(T).fields {
        attach fn ("get_" + f.name)(this: T&) -> f.field_type {
            return @field(this, f.name);
        }
    }
}

struct point {
    x: i32;
    y: i32;
}

comptime getters(point);

// a plain fn, named and numbered by the call
comptime fn counter(name: str, n: i32) -> void {
    fn (name)() -> i32 {
        return n * 10;
    }
}

comptime counter("ten", 1);
comptime counter("twenty", 2);

// in a namespace: a fn and the helper it calls, each seeing tag as it was when it was declared
namespace shapes {
    comptime fn make(name: str, sides: i32) -> void {
        var tag = 1;
        fn (name + "_sides")() -> i32 {
            return helper() + sides + tag;
        }
        tag = 100;
        fn helper() -> i32 {
            return tag;
        }
    }
}

comptime shapes::make("tri", 3);

// a generic comptime fn: the type's array length and the methods use its parameters
<T: type>
comptime fn wrap(n: usize) -> type {
    val W = struct {
        items: T[n];
    };
    attach fn count(this: W&) -> usize {
        return n;
    }
    attach fn first(this: W&) -> T {
        return this.items[0];
    }
    return W;
}

fn main() -> void {
    var ps: soa(particle) = {};
    ps.push({ x: 1.0, y: 2.0, alive: true });
    ps.push({ x: 3.0, y: 4.0, alive: false });
    std::println("{} {} {}", ps.len(), *ps.y.at(1), @typeinfo(soa(particle)).short_name);
    val s = status::parse("GONE") ?? status::OK;
    std::println("{} {} {}", s as i32, status::MOVED as i32, status::parse("NOPE") == null);
    val p: point = { x: 3, y: 4 };
    std::println("{} {}", p.get_x(), p.get_y());
    std::println("{} {}", ten(), twenty());
    std::println("{}", shapes::tri_sides());
    val w: wrap<i32>(4) = { items: { 7, 8, 9, 10 } };
    std::println("{} {}", w.count(), w.first());
}
// expect: 2 4 soa(particle)
// expect: 202 201 true
// expect: 3 4
// expect: 10 20
// expect: 104
// expect: 4 7
