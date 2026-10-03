use std::io;
// Volt imports C++: classes (constructors, destructor as delete, copy constructor as copy, methods,
// overloads, default arguments, static methods), free functions, templates, enums, namespaces
use { "shapes.hpp" } as shapes;

fn main() -> void {
    {
        var s = shapes::geo::Shape::new(2, 3);
        std::println("area {}", s.area());
        s.grow();
        s.grow(2);
        std::println("fields {} {}", s.w(), s.h());
        std::println("scaled {} {}", s.scaled(2), s.scaled(0.5));
        std::println("count {} name {}", shapes::geo::Shape::count(), s.name() ?? "?");
        val sq = shapes::geo::square(4);
        std::println("kind {} {}", @cast<i32>(sq.kind()), @cast<i32>(s.kind()));
        std::println("total {}", shapes::geo::total(&s, &sq));
        val again = copy sq;
        std::println("copied {}", again.area());
    }
    std::println("add {} {}", shapes::geo::add(1, 2), shapes::geo::add(1.5, 2.0));
    std::println("biggest {} {}", shapes::geo::biggest<i32>(3, 9), shapes::geo::biggest<f64>(2.5, 1.5));
    var b: shapes::geo::Box<i32> = { value: 5 };
    b.set(b.get() + 1);
    std::println("box {}", b.value);
    std::println("enum {} {}", @cast<i32>(shapes::geo::Kind::Square), @cast<i32>(shapes::geo::ONE));
    // a trivially copyable class has C++'s layout; any other is one pointer, to C++'s object
    std::println("size {} {}", @sizeof(shapes::geo::Size), @sizeof(shapes::geo::Shape));
    val o = shapes::geo::Owner::new();
    // a class that points into itself survives Volt's moves: the object stays where C++ put it
    var rings: std::vec<shapes::geo::Ring> = {};
    for (i) in 0..20 {
        rings.push(shapes::geo::Ring::new()) catch @panic("out of memory");
    }
    val moved = move rings;
    var ok = 0;
    for (r&) in moved.items() {
        ok += shapes::geo::ring_ok(r);
    }
    val dup = copy *moved.at(3);
    std::println("rings {} {}", ok, dup.intact());
    // a std::string member, through getters and setters
    var nm = shapes::geo::named(4);
    nm.set_n(5);
    nm.set_name("short");
    std::println("named {} {} {} {}", nm.label(), nm.n(), nm.name().len(), nm.size().area);
    val nm2 = copy nm;
    nm.set_n(9);
    std::println("copy keeps {} {}", nm2.n(), nm.n());
    val shelf = shapes::geo::Shelf::new();
    var rec = shapes::geo::Record::new();
    rec.set_x(2);
    std::println("shelf {} record {} {} {} registry {}", shelf.volume(), rec.id().v, rec.x(), shapes::geo::echo(1, 2), shapes::geo::Registry::size());
}
