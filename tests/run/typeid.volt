// @typeid: a type's stable id (the FNV-1a hash of its canonical name) at compile time and at run
// time, and for a trait value the id of the type it holds
use std::io;

trait t_shape {
    fn area(this) -> f64;
}

struct circle { r: f64; }
struct square { side: f64; }

attach t_shape -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}

attach t_shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

trait t_one { fn n(this) -> i32; }
struct only { v: i32 = 1; }
attach t_one -> only {
    fn n(this) -> i32 { return this.v; }
}

// a table built in the compiler
comptime fn ids() -> u64[2] {
    return { @typeid(circle), @typeid(square) };
}
val IDS: u64[2] = ids();

<T: type>
fn id_of() -> u64 { return @typeid(T); }

fn make(round: bool) -> t_shape {
    if (round) {
        val c: circle = { r: 1.0 };
        return c;
    }
    val q: square = { side: 2.0 };
    return q;
}

fn main() -> void {
    std::println("{} {} {}", @typeid(i32), @typeid(u8*), @typeid(std::vec<i32>));
    std::println("{} {}", IDS[0] == @typeid(circle), id_of<square>() == IDS[1]);

    // a value: its type's id, without running it
    val n: i64 = 5;
    std::println("{}", @typeid(n) == @typeid(i64));

    // a trait value, or a reference to one: the type it holds
    var names: std::map<u64, str> = {};
    names.put(@typeid(circle), "circle");
    names.put(@typeid(square), "square");
    val c: circle = { r: 2.0 };
    val q: square = { side: 1.5 };
    val shapes: t_shape[] = { c, q };
    for (s&) in shapes {
        std::print("{} ", *names.get(@typeid(s)));
    }
    std::println("{} {}", @typeid(make(false)) == @typeid(square), @typeid(shapes[0]) != @typeid(t_shape));

    // a registry filled from the trait's own list of types
    var areas: std::map<u64, f64> = {};
    comptime match (@typeinfo(t_shape).kind) {
        .TRAIT_UNION(u) => {
            comptime for (t) in u.1 {
                areas.put(@typeid(t), @sizeof(t) as f64);
            }
        },
        default => {},
    }
    std::println("{} {}", areas.len, *areas.get(@typeid(shapes[1])));

    // a trait with one type; a local named like a type is the local
    val o: only = {};
    val one: t_one = o;
    val square: i32 = 3;
    std::println("{} {}", @typeid(one) == @typeid(only), @typeid(square) == @typeid(i32));
}
// expect: 3094732814638223685 5565575136109896758 14475034361214193807
// expect: true true
// expect: true
// expect: circle square true true
// expect: 2 8
// expect: true true
