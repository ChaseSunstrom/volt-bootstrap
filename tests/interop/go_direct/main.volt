use std::io;
use std::fmt;
use std::thread;
// Volt calling ordinary Go (geom.go, nothing in it is written for Volt): the use line is all it
// takes, with voltc run main.volt or in a bolt package
use { "geom.go" } as geom;
use { "shapes" } as sh;         // a directory with a go.mod: its module's package
use { "tool/tool.go" } as tool; // a main package

fn run() -> geom::go_error!void {
    // plain structs by value, and their methods
    val a: geom::Point = { X: 0.0, Y: 0.0 };
    var b: geom::Point = { X: 3.0, Y: 4.0 };
    std::println("dist {} norm {}", geom::Dist(a, b), b.Norm());
    b.Scale(2.0);
    val m = geom::Mid(a, b);
    std::println("scaled {} {} mid {} {}", b.X, b.Y, m.X, m.Y);
    std::println("{} {} {}", geom::Version, geom::Limit, geom::Ratio);

    // an enum, its method, and a struct holding one (changed through a *Pixel)
    val c = geom::Next(geom::Color::Blue);
    std::println("color {} {}", c.Name(), geom::Color::Green.Name());
    var px: geom::Pixel = { At: { X: 1.0, Y: 2.0 }, Color: geom::Color::Red };
    geom::Brighten(&px);
    std::println("pixel {} {}", px.At.Y, px.Color.Name());

    // text and slices
    val parts: str[3] = { "a", "b", "c" };
    std::println("{} {}", geom::Upper("quiet"), geom::Join(parts[..], "-"));
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("sum {}", geom::Sum(xs[..]));
    var ys: isize[3] = { 1, 2, 3 };
    geom::Double(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sq = geom::Squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val w = geom::Words(" a bb  ccc ");
    std::println("words {} {}", w.len, *w.at(2));

    // (T, bool) is T?, (T, error) and error are go_error results
    val zs: isize[3] = { 5, 7, 9 };
    std::println("find {} {}", geom::Find(zs[..], 9) ?? 99, geom::Find(zs[..], 4) == null);
    std::println("parse {}", try geom::Parse(" 42 "));
    val bad = geom::Parse("x");
    if (bad.err) {
        std::println("bad {}", bad.err);
    }
    try geom::Check(true);

    // any other struct: a handle, and Go keeps the value while Volt holds it
    val sides: f64[3] = { 3.0, 4.0, 5.0 };
    var s = geom::NewShape("tri", sides[..]);
    var q = geom::NewShape("quad", sides[0..2]);
    q.Add(10.0);
    std::println("perimeter {} {} {}", s.Perimeter(), q.Perimeter(), s.Describe());
    std::println("side {}", try s.Side(1));
    val missing = s.Side(9);
    if (missing.err) {
        std::println("missing {}", missing.err);
    }
    var l = geom::Longest(&s, &q);
    l.Add(1.0);
    std::println("longest {} {}", l.Describe(), q.Perimeter());

    // a module's package (which imports another of the module's), and a main package
    std::println("{} {} {}", sh::Area(2.0, 3.0), sh::Label(2.0, 3.0), tool::Version());

    // generics: an instance per use (Max[int], Max[float64], Map[int, string], Stack[int])
    val fs: f64[3] = { 0.5, 2.5, 1.5 };
    std::println("max {} {} ident {}", geom::Max(zs[..]), geom::Max(fs[..]), geom::Ident(7));
    val tags = geom::Map<isize, std::string>(zs[..], || (x: isize) -> std::string { return std::fmt::format("<{}>", x); });
    std::println("map {} {}", tags.len, *tags.at(2));
    var st = geom::Stack<isize>::new();
    st.Push(4);
    st.Push(5);
    val top = st.Pop() ?? 0;
    std::println("stack {} {}", top, st.Len());

    // funcs both ways: Volt closures into Go (a named func type too), Go's back as values to call
    val ns: isize[3] = { 1, 2, 3 };
    std::println("apply {} fold {}", geom::Apply(|| (x: isize) -> isize { return x * 3; }, 5), geom::Fold(ns[..], 0, || (a: isize, b: isize) -> isize { return a + b * b; }));
    val add2 = geom::Adder(2);
    val hi = geom::Greeter("hi");
    std::println("adder {} {}", add2.call(40), hi.call("volt"));
    val corners = geom::Corners(2.0, 1.0);
    val ws: str[3] = { "ok", "bad", "never" };
    val each = geom::Each(ws[..], || (w: str) -> geom::go_error!void {
        if (w == "bad") {
            return geom::go_error::ERROR(std::string::from("no bad words"));
        }
        return;
    });
    std::println("countif {} {}", geom::CountIf(corners.items(), || (p: geom::Point) -> bool { return p.X > 0.0; }), each.err);

    // slices of structs (Go's changes come back), maps, a map as a set, nested slices, handles
    val cs = geom::Corners(2.0, 1.0);
    var ps: geom::Point[2] = { { X: 1.0, Y: 2.0 }, { X: 3.0, Y: 4.0 } };
    val cen = geom::Centroid(ps[..]);
    geom::Shift(ps[..], 10.0);
    std::println("corners {} {} centroid {} {} shifted {}", cs.len, cs.at(2).X, cen.X, cen.Y, ps[0].X);
    val words: str[4] = { "a", "b", "a", "c" };
    var counts = geom::Count(words[..]);
    std::println("count {} {} {} {} {}", counts.len(), counts.get("a") ?? 0, geom::Lookup(&counts, "c"), counts.contains("z"), geom::SumValues<std::string>(&counts));
    var inv = geom::Inventory::new();
    inv.put("apple", 3);
    inv.put("pear", 4);
    inv.remove("none");
    std::println("inventory {} {}", inv.Total(), inv.keys().len);
    val u = geom::Unique(words[..]);
    std::println("unique {} {} {}", u.len(), u.contains("b"), u.contains("z"));
    val seen = geom::Visited(ps[..]);
    std::println("visited {} {} {}", seen.len(), seen.contains({ X: 11.0, Y: 2.0 }), seen.contains({ X: 1.0, Y: 2.0 }));
    val nowhere: geom::Point = {};
    val pl = geom::Places();
    val work = pl.get("work") ?? nowhere;
    std::println("places {} {}", pl.len(), work.X);
    val g = geom::Grid(3);
    val row = g.get(2);
    std::println("grid {} {}", g.len(), *row.at(2));
    var shs = geom::Shapes();
    std::println("names {}", geom::Names(shs.items()));
    val t3 = geom::MakeTriple(1, 2, 3);
    std::println("triple {} {}", t3.Sum(), t3.get(1));

    // channels: a goroutine's values, a Volt closure called from Go's own goroutine, Volt's sends
    val r = geom::Range(4);
    var total: isize = 0;
    while (true) {
        val x = r.recv() ?? break;
        total += x;
    }
    var src = geom::Range(3);
    var piped = geom::Pipe(&src, || (x: isize) -> isize { return x * 10; });
    val got = geom::Collect(&piped);
    var ch = geom::chan<isize>::new(2);
    ch.send(5);
    ch.send(6);
    ch.close();
    val sent = geom::Collect(&ch);
    std::println("chan {} {} {} {}", total, *got.at(2), sent.len, *sent.at(1));

    // an interface: Volt's types and Go's attach it, and Go's values of it come back as handles
    std::println("{}", geom::Tell({ b: 4.0, h: 3.0 } as tri));
    val sq: geom::Square = { Side: 3.0 };
    std::println("{}", geom::Tell(sq));
    val us = geom::UnitSquare();
    std::println("unit {} {}", us.Area(), us.Name());
    val big = geom::Larger(geom::UnitSquare(), { b: 10.0, h: 10.0 } as tri);
    std::println("larger {}", big.Name());

    // pointers to numbers: changed in place, or a handle to Go's
    var n: isize = 5;
    geom::Incr(&n);
    val ctr = geom::NewCounter(41);
    ctr.put(ctr.get() + 1);
    std::println("pointers {} {}", n, ctr.get());

    // several results: a tuple (with Go's names), and with an error
    val (lo, hi2) = geom::MinMax(zs[..]);
    val cut = geom::Cut("key=value", "=");
    val (q, rem) = try geom::Divmod(7, 2);
    std::println("results {} {} {} {} {} {} {}", lo, hi2, cut.before, cut.after, cut.found, q, rem);
    val dz = geom::Divmod(1, 0);
    if (dz.err) {
        std::println("divmod {}", dz.err);
    }

    // variadics take a slice
    std::println("variadic {} {}", geom::Total(zs[..]), geom::Joinf("/", parts[..]));

    // a generic over a slice of slices; callbacks giving several results and a slice
    val chunks = geom::Chunk(zs[..], 2);
    val spread = geom::Spread(|| (n: isize) -> (isize, std::string) { return (n + 1, std::string::from("ab")); });
    val sum = geom::SumOf(|| () -> std::vec<isize> {
        var out: std::vec<isize> = {};
        out.push(4) catch @panic("out of memory");
        out.push(5) catch @panic("out of memory");
        return out;
    });
    std::println("chunks {} {} {} {}", chunks.len(), chunks.get(1).len, spread, sum);
    std::println("store {}", geom::Probe({ n: 7 } as store));

    // an interface whose methods take and give arrays and pointers is a trait; a generic over an
    // array of slices; a Volt list as the type argument where the generic takes []T
    std::println("board {}", geom::Audit({ n: 2 } as board));
    val tw = geom::Twice<isize>(zs[..]);
    var l1: std::vec<isize> = {};
    var l2: std::vec<isize> = {};
    l1.push(1) catch @panic("out of memory");
    l1.push(2) catch @panic("out of memory");
    l2.push(3) catch @panic("out of memory");
    var lists: std::vec<std::vec<isize>> = {};
    lists.push(move l1) catch @panic("out of memory");
    lists.push(move l2) catch @panic("out of memory");
    std::println("twice {} {} len {}", tw.len(), tw.get(1).len, geom::Len<std::vec<isize>>(lists.items()));

    // a panic: the try_ form gives it as an error (the plain form stops the program)
    val oob = geom::try_At(zs[..], 5);
    if (oob.err) {
        std::println("caught {}", oob.err);
    }

    // constants of every type, and a named basic type
    val body: geom::Celsius = { value: 20.0 };
    std::println("consts {} {} {} [{}]", geom::Boiling.Fahrenheit(), body.Fahrenheit(), geom::Small, geom::Tabbed);
}

// a Volt type attaching Go's interface
struct tri {
    b: f64;
    h: f64;
}

attach geom::Figure -> tri {
    fn Area(this) -> f64 { return this.b * this.h / 2.0; }
    fn Name(this) -> std::string { return std::string::from("tri"); }
}

// Go's (T, bool) and func parameters in a trait's methods
struct store {
    n: isize;
}

attach geom::Store -> store {
    fn Get(this, k: str) -> isize? {
        if (k == "a") {
            return this.n;
        }
        return null;
    }
    fn Each(this, f: fn(str) -> bool) -> isize {
        val keys: str[3] = { "x", "y", "stop" };
        var seen: isize = 0;
        for (k) in keys[..] {
            if (!f(k)) {
                break;
            }
            seen += 1;
        }
        return seen;
    }
}

// Go's interface with arrays and pointers in its methods
struct board {
    n: isize;
}

attach geom::Board -> board {
    fn Total(this, row: isize[..]) -> isize {
        var t: isize = 0;
        for (x) in row {
            t += x;
        }
        return t;
    }
    fn Row(this, i: isize) -> std::vec<isize> {
        var out: std::vec<isize> = {};
        for (k) in 0..3 {
            out.push(i + k) catch @panic("out of memory");
        }
        return out;
    }
    fn Home(this) -> geom::Point { return { X: 1.5, Y: 2.0 }; }
    fn Moves(this) -> geom::ptr<isize> {
        var p = geom::ptr<isize>::new();
        p.put(this.n + 5);
        return p;
    }
}

// Go called from several Volt threads at once
fn threads() -> !void {
    var hits: std::thread::atomic_i64 = {};
    {
        var ts: std::vec<std::thread::thread> = {};
        for (k) in 0..4 {
            try ts.push(try std::thread::spawn(|hits&| () {
                for (i) in 0..100 {
                    hits.add(@cast<i64>(geom::Parse(" 7 ") catch |e| 0));
                }
            }));
        }
    }
    std::println("threads {}", hits.load());
}

fn main() -> !void {
    try run();
    try threads();
}
// expect: dist 5 norm 5
// expect: scaled 6 8 mid 3 4
// expect: 1.2 10 0.5
// expect: color red green
// expect: pixel 2 green
// expect: QUIET a-b-c
// expect: sum 7
// expect: doubled 2 4 6
// expect: squares 4 last 16
// expect: words 3 ccc
// expect: find 2 true
// expect: parse 42
// expect: bad ERROR(strconv.Atoi: parsing "x": invalid syntax)
// expect: perimeter 12 17 tri with 3 sides
// expect: side 4
// expect: missing ERROR(no side 9)
// expect: longest quad with 4 sides 18
// expect: 6 6 m² tool 3
// expect: max 9 2.5 ident 7
// expect: map 3 <9>
// expect: stack 5 1
// expect: apply 15 fold 14
// expect: adder 42 hi, volt
// expect: countif 2 ERROR(each: no bad words)
// expect: corners 4 2 centroid 2 3 shifted 11
// expect: count 3 2 1 false 4
// expect: inventory 7 2
// expect: unique 3 true false
// expect: visited 2 true false
// expect: places 2 5
// expect: grid 3 4
// expect: names a+b
// expect: triple 6 2
// expect: chan 6 20 2 6
// expect: tri of area 6
// expect: square of area 9
// expect: unit 1 square
// expect: larger tri
// expect: pointers 6 42
// expect: results 5 9 key value true 3 1
// expect: divmod ERROR(divide by zero)
// expect: variadic 3 a/b/c
// expect: chunks 2 1 ababab 9
// expect: store 7 true false 2
// expect: board 9 3.5 7
// expect: twice 2 1 len 10
// expect: caught PANIC(runtime error: index out of range [5] with length 3)
// expect: consts 212 68 0.25 [tab	here "quoted" é]
// expect: threads 2800
