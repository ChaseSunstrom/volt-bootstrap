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
| any other class | a handle to an object C++ allocates (`new`, and `delete` when the Volt value goes): a public field `f` is the method `f()` (a copy) and `set_f(v)` (when it can be assigned, and the class has no `set_f` of its own); `cpp_type_name()` is its type as C++ names it (the dynamic type, for a class with virtual methods) |
| a public base class `B` (direct or not) | `d.as_B()`: a handle that borrows the object (never deleted), or a `B&` for a class held by value; a base reached by two paths (each its own object) has a cast for each, named by the path: `d.as_B1_A()`, `d.as_B2_A()` |
| a `T*` of a class held by handle | a result: `T?`, a handle borrowing the object (C++ keeps owning it), none for `nullptr`; a parameter: `T*`, so `&h` or `null` |
| a `T&` result (or a `const T&` of a class that can't be copied) | a handle borrowing the object: changes through it are C++'s object's |
| `std::unique_ptr<T>` of a class held by handle | the object, handed over: a result is `T?` (an owning handle, none for an empty one), a parameter takes a `T` (Volt's handle no longer owns it) |
| `dynamic_cast` | `b.as_D()` on a base with virtual methods: a borrowed handle to the `D`, or null when the object isn't one |
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

Two more holes fill what C++ wants at compile time, and aren't passed: `{&i}` is argument `i`, a
Volt function, by its symbol (declared `extern "C"` for the call), and `{=i}` is argument `i`, a
comptime value, as a C++ literal. So a template with non-type parameters gets them, and a call
inside a generic function gets that instance's: `@cpp<i32>("apply<{&0}, {=1}>({2})", step<T>,
@sizeof(T) > 4, x)`.

`VOLT_SHOW_CPP=1` prints the Volt declarations voltc generated from the headers.

## C++ versions

Each import is read and compiled under a C++ standard: the newest both libclang and `$CXX` take
(found once), unless `--cc -std=c++17` sets one for the whole program or `@standard` one for the
import. Headers written for different standards meet in one program, each compiled under its own:
C++98 code that uses what C++17 removed beside C++23 code that needs it.

```volt ignore
@attributes([@standard("c++98")])
use { "legacy.hpp" } as old;   // std::auto_ptr, throw(int)
use { "modern.hpp" } as cpp;   // concepts, std::expected: the newest standard
```

voltc compiles the wrappers in one C++ unit per standard, each including only its imports' headers,
so everything above works under C++98 through C++26: functions, classes and their handles, `try_`
forms, exceptions, and calls worked out per use (which under C++98 give their result by value).
Subclassing a C++ class (`derive`, below) needs its import under C++17 or newer.

## Calls worked out per use

Some C++ has no declaration Volt can write ahead: a variadic template (`template <class... A>`), a
template with non-type parameters (`template <std::size_t N>`), a function whose `auto` result hangs
on its template arguments, a constrained template, a function-like macro. The import declares those
names, and each call is worked out where it's made: clang takes the call with the arguments' types
(choosing among overloads, deducing template arguments, checking concepts) and says what it returns,
and Volt calls that instance. Template arguments written on the call are passed through, numbers
included.

```cpp
// algos.hpp
#define CLAMP01(x) ((x) < 0 ? 0 : (x) > 1 ? 1 : (x))

namespace algo {
template <class... A>
auto sum(A... a) { return (a + ... + 0); }

template <std::size_t N>
std::size_t padded(std::size_t n) { return (n + N - 1) / N * N; }

template <std::integral T>
T halve(T x) { return x / 2; }
}
```

```volt
use std::io;
use { "algos.hpp" } as cpp;

fn main() -> void {
    std::println("{} {}", cpp::algo::sum(1, 2.5, 3), cpp::algo::padded<16>(@cast<usize>(20)));
    std::println("{} {}", cpp::algo::halve(@cast<i64>(9)), cpp::CLAMP01(1.75));
    std::println("{}", @cpp("{0} * {1}", 4, 1.5));
}
// expect: 6.5 32
// expect: 4 1
// expect: 6
```

A call C++ rejects is an error at the Volt call, in clang's words: `cpp::algo::halve(1.5)` says no
`halve` takes a `double`, because `double` doesn't satisfy `integral`. `@cpp` with no result type
(`@cpp("{0} * {1}", 4, 1.5)`) is worked out the same way. A macro's result comes back by value; a
function's reference result stays a reference, as it does for a declared function.

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
// expect: INVALID_ARGUMENT: expected units.cents, not '12'
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
| a `T&&` result | `T`: a copy of what it refers to (for a class held by handle, a new object moved from it, or a borrowed handle when it can't be moved) |
| a `const` or `constexpr` constant (a number, `bool`, enum or text) in a namespace | a `val` of its value |
| a static data member `m` | `T::m()` (a copy) and `T::set_m(v)` when it can be assigned |
| a class or enum inside a class (`Outer::Inner`) | `Outer_Inner`, beside `Outer` (an unscoped enum's names stay in it: `Outer_Mode::Low`) |
| `operator T()` (explicit or not) | `to_T()`: `to_bool()`, `to_i32()`, `to_string()` |
| `operator=` | `assign(v)` |
| a method template | a generic method: `c.cast_to<f64>()` |
| a `std::function<R(A...)>` parameter | `fn(A...) -> R`: a closure or function; C++ calls it while the call lasts (it mustn't keep it) |
| a `std::function` result | `stdcxx::function`: `call(...)` runs it, and it's deleted with the Volt value |
| a `std::function` field | a getter only: setting it from a Volt closure would keep the closure past the call |

### Types by what they can do

Other class templates' instances, from the standard library or any other, read as Volt's own types
by what clang says they can do (the protocols C++'s own library and structured bindings use), not by
their names:

| a type that | reads as |
| --- | --- |
| dereferences to its `T`, tests as a `bool`, and is made from a `T` or from nothing (`std::optional<T>`) | `T?` |
| has `std::tuple_size` and `get<I>` (`std::pair`, `std::tuple`) | a tuple `(A, B, ...)` |
| ...and its elements contiguous, `data()` (`std::array<T, N>`) | `T[N]` |
| has `data()` and `size()` and doesn't own them (`std::span<T>`) | `T[..]` (`str` of `char`s), alive as long as C++ keeps them |
| has `data()` and `size()` and owns them | `std::vec<T>` (`std::string` of `char`s), a copy |
| has `std::variant_size`, `index()` and `get<I>` (`std::variant`) | an enum with a variant each alternative, named after its type (`I32`, `F64`, a class's name) |
| has `begin(r)` and `end(r)` (a container, a view), held by handle | what `for (x) in r` loops over: each `*it`, as it reads in Volt |

Each works both ways (as a parameter and a result), its elements being numbers, `bool`s, enums,
pointers and classes Volt holds by value; one with other elements is held by handle. Any other type
is held by handle with its members worked out per use, `std::map` among them.

```cpp
// stock.hpp
namespace stock {
std::optional<int> find(std::span<const int> xs, int x);
std::tuple<int, int, bool> minmax(std::span<const int> xs);
std::variant<int, double> price(bool exact);
std::map<int, int> counts(std::span<const int> xs);
}
```

```volt
use std::io;
use { "stock.hpp" } as cpp;
use cpp { "map" } as cs;

fn main() -> void {
    val xs: i32[5] = { 4, 9, 4, 1, 9 };
    std::println("{} {}", cpp::stock::find(xs[..], 1) ?? -1, cpp::stock::find(xs[..], 7) == null);
    val (lo, hi, flat) = cpp::stock::minmax(xs[..]);
    std::println("{} {} {}", lo, hi, flat);
    match (cpp::stock::price(false)) {
        .I32(n) => { std::println("{} exactly", n); },
        .F64(x) => { std::println("about {}", x); },
    }
    val counts = cpp::stock::counts(xs[..]);
    for (kv) in counts {
        std::print("{}x{} ", kv.0, kv.1);
    }
    std::println("");
    // the standard library's own headers: their class templates under stdcxx
    var m: cs::stdcxx::map<i64, f64> = {};
    m.insert_or_assign(7, 0.5);
    std::println("{} {}", m.size(), m.contains(7));
}
// expect: 3 true
// expect: 1 9 false
// expect: about 2.75
// expect: 1x1 4x2 9x2
// expect: 1 true
```

A use that names the standard library's own headers (`use cpp { "map", "deque", "ranges" }`)
declares what they declare under `stdcxx` (Volt's `std` is its own): each class template Volt can't
lay out is a generic handle, `cs::stdcxx::map<K, V>`, made by `{}` (or a compile error at the
literal, for an instance with no default constructor) and with its members worked out per use.

A function that can throw (it isn't `noexcept`) also gets a `try_` form that returns the exception
as a `cpp_error` instead of stopping the program. Its variant says which exception it was:
`OUT_OF_RANGE`, `INVALID_ARGUMENT`, `LENGTH_ERROR`, `DOMAIN_ERROR`, `LOGIC_ERROR`, `RANGE_ERROR`,
`OVERFLOW_ERROR`, `UNDERFLOW_ERROR`, `RUNTIME_ERROR`, `BAD_ALLOC` and `BAD_CAST` for the standard
ones, one named after each class of the headers that derives from `std::exception` (the most
derived one that matches), `EXCEPTION` for any other `std::exception` and `UNKNOWN` for a thrown
value that isn't one. `last_exception()`, in the import's namespace, is what the exception said. (A `try_` form isn't made for a function returning a C++
object, a reference or an optional; for one returning a vector, catch the exception in C++.)

## Subclassing a C++ class in Volt

A C++ framework that calls back through virtual methods takes a Volt type in their place. The Volt
struct holds the subclass's state, and attaches the class itself: `attach C -> T { ... }` overrides
`C`'s virtual methods by their own names, any of them (the pure ones it has to). `C::derive(value,
...)` takes the struct and the arguments of one of `C`'s constructors (public or protected), and
makes the C++ object, which holds the Volt value and deletes it with itself:

```volt ignore
use std::io;
use { "widgets.hpp" } as cpp;   // class gui::Widget { virtual int width() const = 0; ... };

struct boxy {
    w: i32;
}

attach cpp::gui::Widget -> boxy {
    fn width(this, self: cpp::gui::Widget&) -> i32 { return this.w; }

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
  methods of `C`.
- A virtual method the struct doesn't override is `C`'s own. A pure one it doesn't override is a
  compile error naming it, and so is a function in the block that isn't one of `C`'s virtual
  methods, or that takes other types (a `self` of another class).
- Inherited virtual methods count (a `Button` block can override the `describe` it inherits from
  `Widget`), and so do private ones that are pure. A private one that isn't pure (or one inherited
  through a base that isn't public) stays `C`'s: the subclass couldn't call `C`'s own when the
  struct doesn't override it.
- What crosses into an override: numbers, `bool`, enums, pointers, strings (`str`, a view for the
  call), classes Volt holds by value (a copy, or a reference for `T&`) and classes held by handle
  (a handle Volt borrows for the call). What comes back: those numbers, enums and pointers, a class
  held by value, and `std::string`. A virtual method with other types stays `C`'s (a comment in the
  generated source says so); a pure one with other types means the class can't be derived from.
- `derive` is there for a class with a virtual method, a public virtual destructor, and not
  `final`. Copying a derived handle copies only the `C` part, as in C++.

### What it costs

The C++ subclass is a template, made once for each Volt type: each override calls that type's
method directly, by its symbol, and a method the type doesn't have calls `C`'s own directly. There's
no table of function pointers and nothing checked at run time; a call from C++ costs what a virtual
call to a C++ subclass does. A type with methods of the same name for two classes (`label()` of a
`Listener` and of a `Plugin`) overrides each class's separately.

Nothing here needs RTTI, so a program built with `-fno-rtti` (`CXX="c++ -fno-rtti"`) subclasses the
same way. `derived<T>()` and the protected members know a derived object from the handle `derive`
made (or `self`, in an override). Only these use RTTI: `as_Derived()` casts, `cpp_type_name()`, and
`derived<T>()` or a protected method on an object C++ handed back (a handle `derive` didn't make);
without RTTI, a cast or a type name stops the program, and `derived<T>()` on such a handle is
`null`.

## Limits

- What doesn't map is left out, with a comment in the generated source: a non-const reference to a
  standard library string or vector, a `std::function` whose signature has a class in it (other than
  text). A function whose parameters or result only a call settles is
  [called per use](#calls-worked-out-per-use) instead.
- A loop over a C++ range holds its iterators in Volt's own words, so they must be trivially copyable
  and destructible (the standard library's and the views' are); C++ reads ranges under C++11 or
  newer.
- A type Volt can't lay out (a class template's instance with private fields, bases or virtual
  methods, like `basic_json`; a lambda's own type; a coroutine's task type) is held by handle,
  named after the type (`basic_json_0`, `lambda_3`) or by the header's `using` alias for it, and its
  members are worked out per use: methods (`d.get("a")`), static functions
  (`json::parse(text)`), constructors (`T::new(...)`) and operators by their Volt names (`op_add`,
  `op_eq`, `op_index`, a lambda's `f.op_call(5)`). A name the class doesn't have is an error in
  clang's words. The import declares one for its own types; another library's (the standard
  library's) come through a call made per use.
  A constant whose value clang can't work out (or a variable that isn't `const`) isn't a `val`.
- Generic arguments written on a method template's call parse when there's one of them, when the
  call passes nothing, or when each can only be a type (`x.get<i32>()`, `x.pair<i32, f64>()`,
  `c.convert<i32, f64>(2)`, `m.find<ns::Key, std::string>(k)`): `f(a.x < b, c > (d))` stays two
  comparisons. Otherwise they come from the call's arguments, as a generic function's can.
- A C++ exception that reaches Volt through a function's plain form stops the program, like a
  panic; its `try_` form returns it as an error. Either way it never passes through Volt frames, and
  a Volt panic (in a method C++ calls, say) ends the program without unwinding through C++'s.
- A borrowed handle (from `as_`, a `T*` or a `T&`) doesn't keep the object alive: it's good while
  what it came from is.
  Passed by value, it gives C++ a copy of the object (an owned handle is moved from), and `copy` of
  it is an object of its own.
- Volt moves values by copying their bytes, which a C++ object that points into itself (as
  libstdc++'s `std::string` does) doesn't survive. So a class clang says isn't trivially copyable
  (`__is_trivially_copyable`, asked of the imported headers) is held by handle: moving it moves the
  pointer, and the object stays where C++ made it. A handle is never empty: `{}` makes the object
  with its default constructor (`new T()`), and for a class that can't be made from nothing `{}` is
  a compile error that says to use `T::new(...)`.
- A class clang says can be copied but whose copy doesn't compile (one holding a
  `std::vector<std::unique_ptr<T>>`: the vector's copy constructor is declared for any element)
  has no `copy`: the import tries each class's copy, and one that fails isn't copyable.
- A class whose destructor isn't public can't be owned by Volt: it has no `T::new`, and only its
  static methods are of use.

[C++ coverage](/volt-bootstrap/interop/cpp-coverage/) sums up what comes through, the libraries
it's tested against, and what can't map, with the way around each.

Runnable examples: [Volt calls C++](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/cpp) and [C++ calls Volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/cpp).
