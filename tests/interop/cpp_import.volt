use std::io;
// Volt imports C++: classes (constructors, destructor as delete, copy constructor as copy, methods,
// overloads, default arguments, static methods), free functions, templates, enums, namespaces
use cpp { "shapes.hpp" } as shapes;

fn main() -> void {
    {
        var s = shapes::geo::Shape::new(2, 3);
        std::println("area {}", s.area());
        s.grow();
        s.grow(2);
        std::println("fields {} {}", s.w, s.h);
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
    std::println("size {}", @sizeof(shapes::geo::Shape));
    val o = shapes::geo::Owner::new();
}
