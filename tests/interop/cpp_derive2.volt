// A Volt type subclassing a C++ class whose virtual methods take a std::map, a class held by
// handle, a std::function and a std::vector to fill, and give back a std::map; copying the derived
// object copies the Volt side too; derived<T>() and cpp_type_name know a derived object without
// RTTI; and the base's destructor isn't virtual (Volt deletes the object as what it is)
use std::io;
use { "derive2.hpp" } as cpp;

struct summer {
    bonus: i32;
}

struct plain {
    n: i32;
}

attach fn delete(this: summer&) -> void {
    std::println("summer {} gone", this.bonus);
}

attach fn copy(this: summer&) -> summer {
    return { bonus: this.bonus + 1000 };
}

attach cpp::dv::Base -> summer {
    fn total(this, self: cpp::dv::Base&, m: cpp::stdcxx::map<i32, i32>&) -> i32 {
        var s = this.bonus;
        for (kv) in m {
            s += kv.1;
        }
        return s;
    }

    fn weigh(this, self: cpp::dv::Base&, it: cpp::dv::Item&) -> i32 { return it.v() * 2; }

    fn run(this, self: cpp::dv::Base&, f: cpp::stdcxx::function) -> i32 { return f.call(7) + this.bonus; }

    fn table(this, self: cpp::dv::Base&, n: i32) -> cpp::stdcxx::map<i32, i32> {
        var m: cpp::stdcxx::map<i32, i32> = {};
        for (i) in 1..n + 1 {
            m.insert_or_assign(i, i * 10);
        }
        return m;
    }

    fn sink(this, self: cpp::dv::Base&, it: cpp::dv::Item&) -> i32 { return it.v() + 100; }

    fn fill(this, self: cpp::dv::Base&, v: cpp::stdcxx::vector<i32>&) -> void {
        v.push_back(this.bonus);
        v.push_back(2);
    }
}

fn main() -> void {
    val s: summer = { bonus: 1 };
    var b = cpp::dv::Base::derive(move s);
    std::println("{} {} {} {} {}", cpp::dv::use_total(&b), cpp::dv::use_weigh(&b), cpp::dv::use_run(&b), cpp::dv::use_table(&b), cpp::dv::use_fill(&b));
    {
        var c = copy b;
        std::println("copy {} {}", cpp::dv::use_total(&c), (c.derived<summer>() ?? @panic("not a summer")).bonus);
    }
    std::println("{} {}", b.tag(), b.cpp_type_name());
    val d = cpp::dv::desc();
    std::println("sink {} top {}", cpp::dv::use_sink(&b), cpp::dv::top(&d));
    // a class derived from (Mid) seen as its base: the cast and the table need no RTTI
    val p: plain = { n: 3 };
    val mid = cpp::dv::Mid::derive(move p);
    val mb = mid.as_Base();
    std::println("mid {} {} {}", cpp::dv::use_total(&mb), mb.cpp_type_name(), mb.derived<summer>() == null);
    // handles C++ gave back: a derived object's still known (without RTTI too), and deleted as what it is
    val r = cpp::dv::same(&b);
    std::println("same {} {}", (r.derived<summer>() ?? @panic("not a summer")).bonus, r.cpp_type_name());
    {
        val o = cpp::dv::pass(copy b) ?? @panic("empty");
        std::println("passed {} {}", cpp::dv::use_total(&o), o.cpp_type_name());
    }
}
