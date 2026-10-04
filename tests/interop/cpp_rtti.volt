// Casts between C++ classes (as_Base borrows the object; as_Derived is null when it isn't one), an
// object's dynamic type, and which exception a try_ form caught
use std::io;
use { "rtti.hpp" } as cpp;

fn report(n: i32) -> void {
    val r = cpp::zoo::try_feed(n) catch |e| {
        std::println("{} {}: {}", n, e, cpp::last_exception());
        return;
    };
    std::println("{} fed {}", n, r);
}

fn main() -> void {
    val d = cpp::zoo::Dog::new();
    val a = d.as_Animal();
    val nd = d.as_Named();
    std::println("{} {} {}", cpp::zoo::speak(&a), cpp::zoo::tag_of(&nd), a.cpp_type_name());
    val back = a.as_Dog() ?? @panic("not a dog");
    std::println("{} {}", back.tricks(), a.as_Cat() == null);
    val c = cpp::zoo::Cat::new();
    val ca = c.as_Animal();
    std::println("{} {} {}", cpp::zoo::speak(&ca), ca.as_Dog() == null, ca.cpp_type_name());
    std::println("{} {}", cpp::zoo::adopt(d.as_Animal()), a.name());
    val owned = copy a;
    std::println("{}", owned.cpp_type_name());
    val r = cpp::zoo::Robo::new();
    val ra = r.as_Animal();
    std::println("{} {}", cpp::zoo::speak(&ra), r.as_Dog().tricks());
    val b = cpp::zoo::Boxed::new();
    std::println("{} {}", cpp::zoo::area(b.as_Size()), b.label());
    report(5);
    report(-1);
    report(500);
    report(7);
    report(8);
    report(9);
    report(10);
    report(11);
    report(12);
}
