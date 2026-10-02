---
title: C++
description: Importing C++ headers, what maps to what, and the limits.
sidebar:
  order: 2
---

`use { "header.hpp" } as ns;` reads C++ headers with libclang and makes their declarations Volt
declarations: the extension (`.hpp`, `.hh`, `.hxx`, `.cpp`...) says it's C++. A C++ header named
`.h`, or a standard one like `vector`, says so outright: `use cpp { "shapes.h", "vector" } as ns;`.
(This is the self-hosted voltc: the bootstrap compiler reads only C headers.)

```cpp
// geometry.hpp
namespace geo {
struct Vec2 {
    double x, y;
    double length() const { return std::sqrt(x * x + y * y); }
};

class Path {
public:
    Path() : count(0) {}
    void add(Vec2 p) { points[count++] = p; }
    double length() const;
private:
    Vec2 points[16];
    int count;
};

template <typename T>
T clamp(T v, T lo, T hi) { return v < lo ? lo : v > hi ? hi : v; }
}
```

```volt
use std::io;
use { "geometry.hpp" } as cpp;

fn main() -> void {
    var path = cpp::geo::Path::new();
    path.add({ x: 0.0, y: 0.0 });
    path.add({ x: 6.0, y: 8.0 });
    path.add({ x: 6.0, y: 8.5 });
    val v: cpp::geo::Vec2 = { x: 3.0, y: 4.0 };
    std::println("{} {} {}", path.length(), v.length(), cpp::geo::clamp<f64>(1.5, 0.0, 1.0));
}
// expect: 10.5 5 1
```

## What maps to what

| C++ | Volt |
| --- | --- |
| namespace | namespace |
| class, struct | a struct with C++'s size and layout: public fields by name, the rest as padding |
| constructors | `T::new(...)`, one per overload (a default argument adds an overload without it) |
| destructor | a `delete` hook (only when the class needs one) |
| copy constructor | a `copy` hook |
| methods, static methods | attached functions, overloads kept |
| functions, function templates | functions, generic functions: `ns::biggest<i32>(a, b)` |
| class templates | generic structs: `ns::Box<f64>` |
| enum, enum class | enums with the same values and tag type |

## How it works

Every imported function becomes a Volt function whose body is one `@cpp<R>("C++ expression",
args)`: `{0}`, `{1}`... are the arguments. voltc writes an `extern "C"` wrapper for each call into a
C++ file, compiles it with `$CXX` (`c++` by default) and links it with `-lstdc++`. You can write
`@cpp` calls yourself for anything the importer leaves out:

```volt
use std::io;
use { "geometry.hpp" } as cpp;

fn scaled_length(v: cpp::geo::Vec2&, k: f64) -> f64 {
    return @cpp<f64>("{0}.length() * {1}", v, k);
}

fn main() -> void {
    val v: cpp::geo::Vec2 = { x: 3.0, y: 4.0 };
    std::println("{}", scaled_length(&v, 1.5));
}
// expect: 7.5
```

`VOLT_SHOW_CPP=1` prints the Volt declarations voltc generated from the headers.

## The standard library, operators and exceptions

Signatures that use the standard library's strings, vectors and smart pointers map to Volt's:

```cpp
// ledger.hpp
namespace ledger {
struct Money {
    long cents;
    Money operator+(const Money& o) const;
    bool operator<(const Money& o) const;
};
long cents(std::string_view s);               // throws std::invalid_argument
Money parse(std::string_view s);
std::string format(Money m);
std::vector<long> running(const std::vector<long>& xs);
class Book { public: explicit Book(int id); int id; };
std::unique_ptr<Book> open_book(int id);
}
```

```volt
use std::io;
use { "ledger.hpp" } as cpp;

fn main() -> void {
    val a = cpp::ledger::parse("12.50");
    val b = cpp::ledger::parse("0.75");
    std::println("{} {}", cpp::ledger::format(a.op_add(&b)), a.op_lt(&b));
    val xs: i64[3] = { 1, 2, 3 };
    val totals = cpp::ledger::running(xs[..]);
    std::println("{} {}", totals.len, *totals.at(2));
    val book = cpp::ledger::open_book(7);
    std::println("book {}", book.get()->id);
    val c = cpp::ledger::try_cents("12") catch |e| {
        std::println("{}: {}", e, cpp::last_exception());
        return;
    };
    std::println("{}", c);
}
// expect: 13.25 false
// expect: 3 6
// expect: book 7
// expect: EXCEPTION: expected units.cents, not '12'
```

| C++ | Volt |
| --- | --- |
| `std::string`, `std::string_view` parameters (by value, `const&`, `&&`) | `str` |
| a `std::string` result | `std::string` (a copy) |
| a `std::string_view` result | `str` (the same bytes, alive as long as C++ keeps them) |
| `std::vector<T>` parameters (by value, `const&`) | `T[..]` |
| a `std::vector<T>` result (`T` a plain value) | `std::vec<T>` (a copy) |
| `std::unique_ptr<T>`, `std::shared_ptr<T>` | `stdcxx::unique_ptr<T>`, `stdcxx::shared_ptr<T>`: `get()`, and `use_count()` for the shared one; deleting one is C++'s destructor, copying a shared one adds an owner |
| operators | methods and functions named after them: `op_add` (`+`), `op_sub`, `op_mul`, `op_div`, `op_rem`, `op_eq`, `op_ne`, `op_lt`, `op_le`, `op_gt`, `op_ge`, `op_index` (`[]`), `op_call` (`()`), `op_neg` (unary `-`), `op_not`, `op_add_assign` (`+=`)... |
| `T&&` parameters | `T`: Volt hands the value over and C++ moves from it |

A function that can throw (it isn't `noexcept`) also gets a `try_` form that returns the error
`cpp_error::EXCEPTION` instead of stopping the program; `last_exception()`, in the import's
namespace, is what the exception said. (A `try_` form isn't made for a function returning a C++
object, a reference or an optional; for one returning a vector, catch the exception in C++.)

## Limits

- What doesn't map is left out, with a comment in the generated source: an rvalue reference
  result, a standard library type other than those above (or a non-const reference to one),
  assignment and conversion operators.
- A C++ exception that reaches Volt through a function's plain form stops the program, like a
  panic; its `try_` form returns it as an error.
- Volt moves values by copying their bytes. A C++ object that points into itself (like libstdc++'s
  `std::string`) should stay behind a pointer.
