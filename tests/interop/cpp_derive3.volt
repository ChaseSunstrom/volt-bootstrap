// A Volt type overriding C++ virtual methods that take a std::string&, give back a reference (a
// number, a laid-out class, a class held by handle), are overloads of one name (the later ones by
// suffixed names), are &-qualified or private (C++'s own stays when the type doesn't override it);
// and one deriving from a class whose pure virtual methods take a std::string& or are private
use std::io;
use { "derive3.hpp" } as cpp;

struct full {
    n: i32;
    pt: cpp::d3::Pt;
    it: cpp::d3::Item;
}

struct bare {
    k: i32;
}

struct sink {
    seen: i32;
}

struct only_a {
    v: i32;
}

struct only_b {
    v: i32;
}

struct pair {
    v: i32;
}

struct shy_b {
    v: i32;
}

attach cpp::d3::Base -> full {
    fn fill(this, self: cpp::d3::Base&, s: std::string&) -> void {
        s.append("-volt");
    }

    fn slot(this, self: cpp::d3::Base&) -> i32& { return &this.n; }

    fn spot(this, self: cpp::d3::Base&) -> cpp::d3::Pt& { return &this.pt; }

    fn pick(this, self: cpp::d3::Base&) -> cpp::d3::Item& { return &this.it; }

    fn draw(this, self: cpp::d3::Base&, x: i32) -> i32 { return x + 1; }

    fn draw_double(this, self: cpp::d3::Base&, x: f64) -> i32 { return @cast<i32>(x * 2.0); }

    fn tag(this, self: cpp::d3::Base&) -> i32 { return 2; }

    fn hook(this, self: cpp::d3::Base&) -> i32 { return this.n + 4; }
}

attach cpp::d3::Sink -> sink {
    fn put(this, self: cpp::d3::Sink&, s: std::string&) -> void {
        s.append("-sunk");
    }

    fn secret(this, self: cpp::d3::Sink&) -> i32 { return this.seen; }
}

// Two's private virtual methods: one, the other, both (two own layers) or neither
attach cpp::d3::Two -> only_a {
    fn a(this, self: cpp::d3::Two&) -> i32 { return this.v; }
}

attach cpp::d3::Two -> only_b {
    fn b(this, self: cpp::d3::Two&) -> i32 { return this.v; }
}

attach cpp::d3::Two -> pair {
    fn a(this, self: cpp::d3::Two&) -> i32 { return this.v; }

    fn b(this, self: cpp::d3::Two&) -> i32 { return this.v + 1; }
}

// a private virtual Shy inherits through its protected base
attach cpp::d3::Shy -> shy_b {
    fn b(this, self: cpp::d3::Shy&) -> i32 { return this.v; }
}

fn main() -> void {
    val f: full = { n: 10, pt: { x: 1, y: 2 }, it: cpp::d3::Item::new(7) };
    var b = cpp::d3::Base::derive(move f);
    std::println("{} {} {} {}", cpp::d3::use_fill(&b), cpp::d3::use_slot(&b), cpp::d3::use_spot(&b), cpp::d3::use_pick(&b));
    std::println("{} {} {} n {}", cpp::d3::use_draw(&b), cpp::d3::use_tag(&b), cpp::d3::use_run(&b), (b.derived<full>() ?? @panic("not a full")).n);
    // a type overriding none of them: C++'s own, the private one too
    val e: bare = { k: 1 };
    var c = cpp::d3::Base::derive(move e);
    std::println("{} {} {} {}", cpp::d3::use_fill(&c), cpp::d3::use_slot(&c), cpp::d3::use_spot(&c), cpp::d3::use_pick(&c));
    std::println("{} {} {}", cpp::d3::use_draw(&c), cpp::d3::use_tag(&c), cpp::d3::use_run(&c));
    // Mid's draw(int) hides Base's draw(double): a type not overriding draw_double gets Base's
    val e2: bare = { k: 2 };
    val m = cpp::d3::Mid::derive(move e2);
    val mb = m.as_Base();
    std::println("mid {}", cpp::d3::use_draw(&mb));
    val p1: only_a = { v: 5 };
    var t1 = cpp::d3::Two::derive(move p1);
    val p2: only_b = { v: 6 };
    var t2 = cpp::d3::Two::derive(move p2);
    val p3: pair = { v: 7 };
    var t3 = cpp::d3::Two::derive(move p3);
    val p4: bare = { k: 3 };
    var t4 = cpp::d3::Two::derive(move p4);
    std::println("two {} {} {} {}", cpp::d3::use_both(&t1), cpp::d3::use_both(&t2), cpp::d3::use_both(&t3), cpp::d3::use_both(&t4));
    val p5: shy_b = { v: 9 };
    var s5 = cpp::d3::Shy::derive(move p5);
    std::println("shy {}", cpp::d3::use_all(&s5));
    val s: sink = { seen: 42 };
    var k = cpp::d3::Sink::derive(move s);
    std::println("{}", cpp::d3::use_put(&k));
}
