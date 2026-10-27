// C++ with no standard library and no exceptions: the import's wrappers include no std header and
// catch nothing (CXX="c++ -nostdinc++ -fno-exceptions"), and every kind of call still works
use std::io;
use { "cpp_freestanding.hpp" } as cpp;

fn inc(x: i32) -> i32 {
    return x + 1;
}

fn main() -> void {
    val a: cpp::bare::vec2 = { x: 1, y: 2 };
    val s = cpp::bare::add(a, { x: 10, y: 20 });
    std::println("add {} {}", s.x, s.y);
    {
        var c = cpp::bare::counter::new(5);
        c.bump(3);
        c.bump();
        std::println("counter {} live {}", c.get(), cpp::bare::live_count());
    }
    std::println("live {}", cpp::bare::live_count());
    std::println("twice {} {}", cpp::bare::twice(21), cpp::bare::twice(1.5));
    std::println("code {}", cpp::bare::code(cpp::bare::color::blue));
    std::println("apply {} {}", cpp::bare::apply(inc, 4), cpp::bare::call_with(|| (x: i32) -> i32 { return x * 10; }, 4));
}
// expect: add 11 22
// expect: counter 9 live 1
// expect: live 0
// expect: twice 42 3
// expect: code 3
// expect: apply 5 41
