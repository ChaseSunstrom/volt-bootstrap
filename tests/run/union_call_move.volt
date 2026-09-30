// a trait-union method call checks its arguments per member type, but runs one case: a moved
// argument is fine and deleted once
use std::io;
struct r { n: i32; }
attach fn delete(this: r&) -> void { std::println("del {}", this.n); }
trait t_eat {
    fn eat(this, x: r) -> void;
}
struct a1 { k: i32; }
struct a2 { k: i32; }
attach t_eat -> a1 {
    fn eat(this, x: r) -> void { std::println("a1 {}", x.n); }
}
attach t_eat -> a2 {
    fn eat(this, x: r) -> void { std::println("a2 {}", x.n); }
}
fn main() -> void {
    val w: a1 = { k: 1 };
    val u: t_eat = w;
    val v: r = { n: 5 };
    u.eat(move v);
}
// expect: a1 5
// expect: del 5
