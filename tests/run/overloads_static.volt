use std::io;

<T: type>
attach fn make(static this: T) -> T { return 0; }

<T: type>
attach fn make(static this: T) -> T? { return null; }

<T: type, U: type>
attach fn pair_of(static this: T, u: U) -> (T, U) { return (0, u); }

trait storing {
    <T: type> fn put(this, v: T) -> i32;
}

struct store { count: i32; }
attach storing -> store {
    <T: type> fn put(this, v: T) -> i32 {
        this.count += 1;
        return this.count;
    }
}

<T: type>
trait holder {
    fn get(this) -> T;
}

<T: type>
struct cell { v: T; }

<T: type>
attach holder<T> -> cell<T> {
    fn get(this) -> T { return this.v; }
}

<B: holder<i32>>
fn read(b: B&) -> i32 { return b.get(); }

fn main() -> void {
    val a: i32 = i32::make();
    val b: i32? = i32::make();
    std::println("{} {}", a, b);
    val p = u8::pair_of<str>("hi");
    std::println(p);
    var s: store = { count: 0 };
    s.put(1);
    std::println(s.put<str>("x"));
    var c: cell<i32> = { v: 9 };
    std::println("{} {}", c.get(), read(&c));
}
// expect: 0 null
// expect: (0, hi)
// expect: 2
// expect: 9 9
