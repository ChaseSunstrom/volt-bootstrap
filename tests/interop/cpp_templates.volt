// C++ that Volt's generics can't declare, called per use: clang works out each call (overloads,
// deduction, concepts) and its result type, and Volt calls the instance
use std::io;
use { "templates.hpp" } as cpp;

fn main() -> void {
    // variadic templates
    std::println("{} {}", cpp::tpl::sum(1, 2.5, 3), cpp::tpl::count_args(1, "two", 3.0, true));
    // a non-type template parameter
    std::println("{}", cpp::tpl::times<3>(4));
    // auto results that hang on the template's types
    std::println("{} {}", cpp::tpl::doubled(21), cpp::tpl::doubled(1.25));
    val p = cpp::tpl::origin_of(3);
    std::println("{} {}", p.x, p.y);
    // a constrained template
    std::println("{}", cpp::tpl::twice(@cast<i64>(20)));
    // function-like macros
    std::println("{} {}", cpp::SQUARE(5), cpp::PICK(false, 1, 2));
    // method templates: two explicit arguments, and variadic
    val c: cpp::tpl::Conv = { k: 3 };
    std::println("{} {}", c.convert<i32, f64>(2), c.all(1, 2, 3));
    // @cpp with its result type worked out by clang
    std::println("{}", @cpp("{0} * {1}", 4, 1.5));
}
// expect: 6.5 4
// expect: 12
// expect: 42 2.5
// expect: 3 6
// expect: 40
// expect: 25 2
// expect: 6 18
// expect: 6
