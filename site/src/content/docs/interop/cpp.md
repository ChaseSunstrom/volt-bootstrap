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
| a trivially copyable class or struct | a struct with C++'s size and layout: public fields by name, the rest as padding |
| a class with virtual methods | a handle, as below, and a Volt type can subclass it (see [Subclassing](#subclassing-a-c-class-in-volt)) |
| any other class | a handle to an object C++ allocates (`new`, and `delete` when the Volt value goes): a public field `f` is the method `f()` (a copy) and `set_f(v)` (when it can be assigned, and the class has no `set_f` of its own) |
| constructors | `T::new(...)`, one per overload (a default argument adds an overload without it); `T::new()` for a class that declares none, when it can be made from nothing |
| destructor | a `delete` hook (only when the class needs one) |
| copy constructor | a `copy` hook (a handle's copies the object with it) |
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

## Subclassing a C++ class in Volt

A C++ framework that calls back through virtual methods takes a Volt type in their place. The Volt
struct holds the subclass's state; each virtual method `m` of class `C` has a trait `t_C_m` in the
import's namespace, and the struct attaches the ones it overrides. `C::derive(value, ...)` takes the
struct and the arguments of one of `C`'s constructors (public or protected), and makes the C++
object, which holds the Volt value and deletes it with itself:

```volt ignore
use std::io;
use { "widgets.hpp" } as cpp;   // class gui::Widget { virtual int width() const = 0; ... };

struct boxy {
    w: i32;
}

attach cpp::gui::t_Widget_width -> boxy {
    fn width(this, self: cpp::gui::Widget&) -> i32 { return this.w; }
}

attach cpp::gui::t_Widget_click -> boxy {
    fn click(this, self: cpp::gui::Widget&, times: i32) -> void {
        this.w += times;
        self.bump(times);       // a protected method
        self.base_click(times); // Widget's own click
    }
}

fn main() -> void {
    val b: boxy = { w: 3 };
    var w = cpp::gui::Widget::derive(move b, "ok");
    std::println("{}", cpp::gui::show(&w));      // C++ calls width() and click(): Volt's
    val mine = w.derived<boxy>() ?? @panic("?"); // the Volt value back
}
```

- An override gets the C++ object as `self`, a `C&`: through it, `base_m(...)` is `C`'s own `m`
  (not for a pure one), and `C`'s protected methods and fields (`f()`, `set_f(v)`) are there too, as
  methods of `C`. On an object Volt didn't make with `derive`, a protected one stops the program.
- A virtual method the struct doesn't override is `C`'s own. A pure one it doesn't override is a
  compile error naming the trait to attach.
- Inherited virtual methods count (`t_Button_describe` for a `describe` `Button` inherits), and so
  do private ones that are pure. A private one that isn't pure stays `C`'s: the subclass couldn't
  call `C`'s own when the struct doesn't override it.
- What crosses into an override: numbers, `bool`, enums, pointers, strings (`str`, a view for the
  call), classes Volt holds by value (a copy, or a reference for `T&`) and classes held by handle
  (a handle Volt borrows for the call). What comes back: those numbers, enums and pointers, a class
  held by value, and `std::string`. A virtual method with other types stays `C`'s (a comment in the
  generated source says so); a pure one with other types means the class can't be derived from.
- `derive` is there for a class with a virtual method, a public virtual destructor, and not
  `final`. Copying a derived handle copies only the `C` part, as in C++.

## Limits

- What doesn't map is left out, with a comment in the generated source: an rvalue reference
  result, a standard library type other than those above (or a non-const reference to one),
  assignment and conversion operators.
- A C++ exception that reaches Volt through a function's plain form stops the program, like a
  panic; its `try_` form returns it as an error.
- Volt moves values by copying their bytes, which a C++ object that points into itself (as
  libstdc++'s `std::string` does) doesn't survive. So a class clang says isn't trivially copyable
  (`__is_trivially_copyable`, asked of the imported headers) is held by handle: moving it moves the
  pointer, and the object stays where C++ made it. A handle made with `{}` is empty, and using it
  stops the program.
- A handle class can't be reached through a C++ pointer (`T*`), a non-const reference result (`T&`)
  or a smart pointer or class template over it; those are left out, as is a class template with a
  field of one. A `const T&` result is copied into a new handle, so it's left out when the class
  can't be copied (an abstract one, say).
- A class whose destructor isn't public can't be owned by Volt: it has no `T::new`, and only its
  static methods are of use.

Runnable examples: [Volt calls C++](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/cpp) and [C++ calls Volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/cpp).
