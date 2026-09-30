use std::io;

// runs while compiling: the result is a constant in the program
comptime fn fib(n: i32) -> i32 {
    var a = 0;
    var b = 1;
    for (i) in 0..n {
        val next = a + b;
        a = b;
        b = next;
    }
    return a;
}

// a pack of types: the loop unrolls, each arg has its own type
<Args: type...>
fn show(args: Args...) -> void {
    comptime for (arg) in args {
        std::print("{}:{} ", @typeinfo(@typeof(arg)).short_name, arg);
    }
    std::println("");
}

fn main() -> void {
    val table: i32 = fib(20);
    show(table, 2.5, true, "volt");
}
// expect: i32:6765 f64:2.5 bool:true str:volt 
