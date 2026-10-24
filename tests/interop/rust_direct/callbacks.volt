use std::io;
use std::string;
use std::fmt;
// Volt closures and a Volt type's trait methods that Rust calls with structs, enums, handles, Vec,
// slices, arrays and Option, and that give them back
use { "geom" } as geom;

struct walker {
    calls: i32;
}

attach geom::Visit -> walker {
    fn at(this, p: geom::Point, c: geom::Color) -> geom::Point? {
        this.calls += 1;
        if (c == geom::Color::Red) {
            return null;
        }
        val q: geom::Point = { x: p.x * 10.0, y: p.y + @cast<f64>(this.calls) };
        return q;
    }
    fn many(this, xs: i32[..], label: str?) -> std::vec<std::string> {
        var out: std::vec<std::string> = {};
        val tag = label ?? "?";
        for (x) in xs {
            out.push(std::fmt::format("{}{}", tag, x)) catch @panic("out of memory");
        }
        return out;
    }
    fn edit(this, p: geom::Point&) -> void {
        p.x = -p.x;
    }
    fn sized(this, t: geom::Tally&, c: geom::Color?) -> (i32, geom::Color) {
        return (t.total() * 2, c ?? geom::Color::Blue);
    }
    fn made(this) -> geom::Tally {
        return geom::Tally::new(this.calls);
    }
}

fn main() -> void {
    val m = geom::map_point({ x: 1.0, y: 2.0 }, || (p: geom::Point) -> geom::Point { return { x: p.y, y: p.x }; });
    std::println("map {} {}", m.x, m.y);
    val n = geom::nudge({ x: 1.0, y: 1.0 }, || (p: geom::Point&) -> void { p.y += 5.0; });
    std::println("nudge {} {}", n.x, n.y);
    std::println("shift {} {}", geom::shift_color(geom::Color::Red, || (c: geom::Color, p: geom::Point&) -> geom::Color? { if (p.y > 1.0) { return geom::Color::Green; } return c; }), geom::shift_color(geom::Color::Blue, || (c: geom::Color, p: geom::Point&) -> geom::Color? { return null; }));
    val xs: i32[5] = { 1, 2, 3, 4, 5 };
    std::println("evens {}", geom::evens(xs[..], || (v: i32[..], by: i32?) -> std::vec<i32> {
        var out: std::vec<i32> = {};
        for (x) in v {
            if (x % (by ?? 1) == 0) {
                out.push(x) catch @panic("out of memory");
            }
        }
        return out;
    }));
    std::println("words {}", geom::words_of("a bb ccc", || (ws: str[..]) -> (usize, std::string?) {
        if (ws.len == 0) {
            return (0, null);
        }
        return (ws.len, std::string::from(ws[ws.len - 1]));
    }));
    std::println("spend {}", geom::spend(geom::Tally::new(5), || (t: geom::Tally&, k: geom::Tally&) -> geom::Tally { return geom::Tally::new(t.total() + k.total()); }));
    std::println("spots {}", geom::spots(|| (p: geom::Point?) -> std::vec<i32> {
        var out: std::vec<i32> = {};
        val q = p ?? { x: 0.0, y: 0.0 } as geom::Point;
        out.push(@cast<i32>(q.x)) catch @panic("out of memory");
        out.push(@cast<i32>(q.y)) catch @panic("out of memory");
        out.push(@cast<i32>(q.x + q.y)) catch @panic("out of memory");
        return out;
    }));
    var w: walker = { calls: 0 };
    std::println("visit {}", geom::run_visit(&w));
    std::println("calls {}", w.calls);
}
// expect: map 2 1
// expect: nudge 1 6
// expect: shift Green none
// expect: evens [2, 4] [1, 2, 3, 4, 5]
// expect: words 3 Some("ccc")
// expect: spend 105
// expect: spots [0, 0, 0] [3, 4, 7]
// expect: visit Some(Point { x: 10.0, y: 3.0 }) None ["xs1", "xs2", "xs3"] Point { x: -5.0, y: 6.0 } ((14, Blue), (14, Green)) 2 [true, false]
// expect: calls 2
