use std::io;

fn repeat(comptime n: i32, c: str) -> void {
    comptime for (i) in 0..n {
        std::print(c);
    }
    std::println();
}

fn greet(comptime who: str) -> str {
    comptime if (who == "world") {
        return "hello, world";
    }
    return "hi";
}

<T: type>
fn only_ints(v: T) -> T {
    comptime if (!@typeinfo(T).is_pod) {
        @compile_error("only plain values");
    }
    return v;
}

@attributes([@inline])
fn fast(x: i32) -> i32 { return x + 1; }

@attributes([@noinline, @section(".text.volt")])
fn slow(x: i32) -> i32 { return x - 1; }

@attributes([@deprecated("use fast")])
fn old(x: i32) -> i32 { return x; }

fn main() -> void {
    repeat(3, "ab");
    repeat(1, "z");
    std::println("{} {}", greet("world"), greet("you"));
    std::println(only_ints(5));
    std::println("{} {} {}", fast(1), slow(1), old(7));
}
// expect: ababab
// expect: z
// expect: hello, world hi
// expect: 5
// expect: 2 0 7
