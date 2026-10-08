use std::io;
// Rust's ownership forms (every self form, references into Rust's data) and errors (an enum's
// variants, a panic caught), async fns awaited
use { "geom" } as geom;

fn parsed(s: str) -> void {
    val n = geom::parse_digits(s) catch |e| {
        match (e) {
            .Empty => std::println("empty"),
            .BadDigit(c) => std::println("bad digit {}", c),
            .TooLong(max, got) => std::println("too long {} > {}", got, max),
            .Raw(text) => std::println("raw {}", text),
        }
        return;
    };
    std::println("parsed {}", n);
}

fn parsed_later(s: str) -> void {
    val n = geom::parse_later(s) catch |e| {
        std::println("async error {}", e);
        return;
    };
    std::println("async parsed {}", n);
}

// a Rust closure's panic (a FnOnce called twice), as an error
fn twice_once() -> void {
    val once = geom::initial_of("w");
    std::println("once {}", once.call());
    val again = once.try_call() catch |e| {
        std::println("closure {}", e);
        return;
    };
    std::println("not reached {}", again);
}

fn connect(code: i32) -> void {
    val n = geom::connect(code) catch |e| {
        match (e) {
            .Timeout => std::println("timeout"),
            .Refused(why) => std::println("refused {}", why),
            .Closed => std::println("closed"),
            .Other(text) => std::println("other {}", text),
        }
        return;
    };
    std::println("connected {}", n);
}

// a panic in a method lent its value through &Rc<Self>: the value is the handle's again, dropped
// once
fn lent_panic() -> void {
    {
        val c = geom::Counted::new(7);
        val ok = c.try_peek(false) catch -1;
        val bad = c.try_peek(true) catch -2;
        std::println("peek {} {} drops {}", ok, bad, geom::counted_drops());
    }
    std::println("counted drops {}", geom::counted_drops());
}

fn main() -> void {
    var n = geom::Node::new(4);
    n.bump_pinned();
    std::println("self {} {} {}", n.read_pinned(), n.peek_rc(), n.boxed_value());
    std::println("rc {} arc {}", geom::Node::new(2).rc_value(), geom::Node::new(3).arc_value());
    var t = geom::Tree::new(3);
    t.first_mut().set(10);
    val found = t.find(2) ?? return;
    val all = t.all();
    std::println("refs {} {} {} {}", t.first().value(), found.value(), all.len, all.at(2).value());
    val owned = t.into_nodes();
    val cs = geom::corners();
    val pal = geom::palette();
    std::println("vecs {} {} {} {}", owned.len, cs.at(1).y, pal.len, *pal.at(1) == geom::Color::Blue);
    val f = async geom::later(1);
    val node = geom::Node::new(9);
    std::println("async {} {} {}", await f, geom::from_thread(21), await node.value_later());
    parsed_later("4y");
    parsed("42");
    parsed("");
    parsed("4x");
    parsed("12345");
    parsed("#1");
    connect(0);
    connect(1);
    connect(2);
    connect(5);
    lent_panic();
    twice_once();
    val xs: i32[3] = { 7, 8, 9 };
    val ok = geom::try_at(xs[..], 1) catch -1;
    val bad = geom::try_at(xs[..], 5) catch |e| {
        std::println("caught {}", e);
        return;
    };
    std::println("not reached {} {}", ok, bad);
}
