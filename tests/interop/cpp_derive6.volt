// A Volt type overriding virtual operators (op_eq, op_call), an && method and C variadic virtuals,
// which get a void* to the call's va_list (read with va_arg through @cpp); a type overriding only
// the pure variadic one keeps C++'s own for the rest
use std::io;
use { "derive6.hpp" } as cpp;

struct all {
    k: i32;
}

struct few {
    k: i32;
}

attach cpp::d6::V -> all {
    fn op_eq(this, self: cpp::d6::V&, x: i32) -> bool { return x == this.k; }

    fn op_call(this, self: cpp::d6::V&, a: i32, b: i32) -> i32 { return a * b; }

    fn take(this, self: cpp::d6::V&) -> i32 { return 42; }

    fn log(this, self: cpp::d6::V&, fmt: cstr?, va: void*) -> i32 { return @cpp<i32>("va_arg(*(va_list *){0}, int)", va); }

    fn sum(this, self: cpp::d6::V&, n: i32, va: void*) -> i32 {
        var t = 0;
        for (i) in 0..n {
            t += @cpp<i32>("va_arg(*(va_list *){0}, int)", va);
        }
        return t;
    }
}

attach cpp::d6::V -> few {
    fn sum(this, self: cpp::d6::V&, n: i32, va: void*) -> i32 { return n; }
}

fn main() -> void {
    val a: all = { k: 5 };
    var v = cpp::d6::V::derive(move a);
    std::println("all {} {} {} {} {}", cpp::d6::eq(&v, 5), cpp::d6::call(&v), cpp::d6::taken(&v), cpp::d6::logged(&v), cpp::d6::summed(&v));
    val f: few = { k: 1 };
    var w = cpp::d6::V::derive(move f);
    std::println("few {} {} {} {} {}", cpp::d6::eq(&w, 5), cpp::d6::call(&w), cpp::d6::taken(&w), cpp::d6::logged(&w), cpp::d6::summed(&w));
}
