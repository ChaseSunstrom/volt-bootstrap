// A Volt type overriding a virtual method whose & twin comes after its && one (the & one is g), the
// later of two overloads that differ only in const (h_nonconst, k_const, p_int_const), and the
// virtual d_double beside a d(double) that stays C++'s (its suffixed name is taken); a type
// overriding none keeps C++'s own
use std::io;
use { "derive4.hpp" } as cpp;

struct mine {
    n: i32;
    it: cpp::d4::Item;
}

struct bare {
    k: i32;
}

attach cpp::d4::Q -> mine {
    fn g(this, self: cpp::d4::Q&) -> i32 { return this.n; }

    fn h(this, self: cpp::d4::Q&) -> i32 { return 20; }

    fn h_nonconst(this, self: cpp::d4::Q&) -> i32 { return 30; }

    fn k(this, self: cpp::d4::Q&) -> i32 { return 40; }

    fn k_const(this, self: cpp::d4::Q&) -> i32 { return 50; }

    fn p(this, self: cpp::d4::Q&, x: i32) -> i32 { return x + 60; }

    fn p_int_const(this, self: cpp::d4::Q&, x: i32) -> i32 { return x + 70; }

    fn d(this, self: cpp::d4::Q&, x: i32) -> i32 { return x + 80; }

    fn d_double(this, self: cpp::d4::Q&) -> i32 { return 90; }

    fn pick(this, self: cpp::d4::Q&) -> cpp::d4::Item& { return &this.it; }
}

fn main() -> void {
    val m: mine = { n: 7, it: cpp::d4::Item::new(8) };
    var q = cpp::d4::Q::derive(move m);
    std::println("{} {} {} {} {} {}", cpp::d4::use_g(&q), cpp::d4::use_h(&q), cpp::d4::use_k(&q), cpp::d4::use_p(&q), cpp::d4::use_d(&q), cpp::d4::use_pick(&q));
    val b: bare = { k: 1 };
    var c = cpp::d4::Q::derive(move b);
    std::println("{} {} {} {} {} {}", cpp::d4::use_g(&c), cpp::d4::use_h(&c), cpp::d4::use_k(&c), cpp::d4::use_p(&c), cpp::d4::use_d(&c), cpp::d4::use_pick(&c));
}
