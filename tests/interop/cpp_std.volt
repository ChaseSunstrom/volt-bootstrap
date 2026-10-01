use std::io;
// Volt imports C++ that uses the standard library: std::string and std::string_view cross as str
// (in) and std::string (out), std::vector as slices (in) and std::vec (out), std::unique_ptr and
// std::shared_ptr as stdcxx:: types; operators become op_ methods; T&& takes the value; and a
// function that can throw has a try_ form that returns the exception as an error
use cpp { "stdtypes.hpp" } as cxx;

fn main() -> void {
    val g = cxx::lib::greet("volt");
    std::println("{} {}", g, cxx::lib::count("banana", 'a'));
    std::println("first {}", cxx::lib::first_word("lorem ipsum"));
    val xs: f64[3] = { 1.0, 2.0, 3.5 };
    std::println("sum {}", cxx::lib::sum(xs[..]));
    val r = cxx::lib::range(4);
    std::println("range {} {}", r.len, *r.at(3));
    val a: cxx::lib::Vec2 = { x: 1.0, y: 2.0 };
    val b: cxx::lib::Vec2 = { x: 3.0, y: 4.0 };
    var c = a.op_add(&b);
    std::println("vec {} {} {}", c.x, c.op_neg().y, c.op_index(1));
    c.op_add_assign(&a);
    std::println("eq {} {}", c.op_eq(&c), cxx::lib::op_mul(&c, 2.0).x);
    {
        var n = cxx::lib::make_node(4);
        std::println("node {}", n.get()->value);
        std::println("taken {}", cxx::lib::take_node(move n));
    }
    val s = cxx::lib::share_node(7);
    val s2 = copy s;
    std::println("shared {} {}", s2.get()->value, cxx::lib::uses(&s));
    var buf = cxx::lib::Buffer::new();
    buf.append("ab");
    buf.append("cd");
    std::println("buffer {} {}", buf.str(), buf.size());
    std::println("parse {}", cxx::lib::try_parse("42") catch -1);
    val bad = cxx::lib::try_parse("4x") catch -1;
    std::println("bad {} {}", bad, cxx::last_exception());
    cxx::lib::try_must_be_positive(-1) catch |e| {
        std::println("error {} {}", e, cxx::last_exception());
    };
}
