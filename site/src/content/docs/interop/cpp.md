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
| numbers, pointers, `const char*` | as from [C](/volt-bootstrap/interop/c/): `i32`, `T*`, `cstr?`; an `int&` is an `i32&` |
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
| overloads Volt can't tell apart (`long` and `long long` are both `i64`, `char` is `signed char`'s or `unsigned char`'s twin depending on the target (signed on x86-64, unsigned on arm64 Linux), so which overload collides depends on the target, a `const` method's `this` is a non-`const` one's) | the first declared keeps the name; each other one is named for its parameters' C++ types, after the namespace's own names: `which_long_long(x)`, `letter_char(c)` (when `char` comes after the other two), `T::new_long_long(n)`, `get_const()` (words joined by `_`, `*` as `ptr`, `&` as `ref`, `&&` as `rref`; when only its qualifiers differ, `const`, `lref`, `rref` or `nonconst` instead: `get_nonconst()` after a `get() const`), its default-argument forms too, and calls exactly that overload. A name a real declaration (or another such name) has is a `// left out:` comment instead, and so is a real declaration in a later block of the namespace whose name an alias has |
| a method qualified `&&` on a class held by handle | an attached function taking `this` by value: the handle is consumed (using it afterwards is a use after move), and C++ moves from the object, or from a copy of it when the handle only borrows it (`as_Base()`). A class that can be neither copied nor moved has no copy to make: an owned handle's object runs the method, and a borrowed handle stops the program with `can't call Q::m (an && method) through a borrowed handle: Q can't be copied` (worked out per use, as an inherited `&&` method is, such a class's call is an error); its `const &&` methods, and an abstract class's `&&` ones, run in place on the object, borrowed or not, the handle kept. On a class template's instance (worked out per use) the same, for a method only an rvalue can call (when `&` and `&&` overloads share the name, the call is the `&` one's), and `derive`'s `base_m()` and protected forms leave it out with a comment: their object is the Volt subclass's |
| functions, function templates | functions, generic functions: `ns::biggest<i32>(a, b)` |
| a Volt `std::string` for a function template's parameter (`template <class S> void wrap(S&)`) | a C++ `std::string`: `ns::wrap(&text)` instantiates `wrap<std::string>`. For `S&` C++ changes a copy, which the Volt string gets once the call returns (not when it throws: a `try_` form leaves it as it was); for `const S&` and `S` the copy is made from the text and nothing comes back. Overloads resolve as C++'s for `f(s)`: a string Volt may change (a `var`, or a reference to one) runs `S&` over `const S&`, and a forwarding `S&&` changes it; a `val` or a `str` runs `const S&`, in `@cpp` and through the template's Volt generic alike. C++ never writes into a string Volt can't change: a `val` (or a temporary) for a template that takes only `S&` is an error, as C++ refuses it (`'k' is a val, and wrap changes it`). Only `S` itself takes one: `S` in another type (`S*`, `std::vector<S>&`) or as the result is an error |
| class templates | generic structs: `ns::Box<f64>`; one with private fields, bases, virtual methods or a field with no Volt form is a generic handle (`ns::box<i32>`), its public fields getters and `set_` methods, its other members worked out per use |
| enum, enum class | enums with the same values and tag type (an unscoped enum's names are also constants beside it: `ns::ONE`) |

A Volt fn can be attached to an imported class, held by value or by handle, as to any type:
`attach fn dollars(this: cpp::bank::money&) -> f64 { ... }`
([attach-foreign](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/attach-foreign)
does it for a C struct and two C++ classes).

## How it works

Every imported function becomes a Volt function whose body is one `@cpp<R>("C++ expression",
args)`: `{0}`, `{1}`... are the arguments. voltc writes an `extern "C"` wrapper for each call into a
C++ file, compiles it with `$CXX` (`c++` by default) and links it with `-lstdc++`. A reference
argument arrives as the object it names, and a Volt function's name as a pointer to it
(`@cpp<i32>("ns::apply({0}, {1})", inc, 4)`). You can write
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

More holes fill what C++ wants at compile time, and aren't passed: `{&i}` is argument `i`, a
Volt function, by its symbol (declared `extern "C"` for the call), and `{=i}` is argument `i`, a
comptime value, as a C++ literal; `{t0}`, `{t1}`... are the types written after the result's
(`@cpp<R, T>`), as C++ names them. So a template with non-type parameters gets them, and a call
inside a generic function gets that instance's: `@cpp<i32>("apply<{&0}, {=1}>({2})", step<T>,
@sizeof(T) > 4, x)`, `@cpp<T, T>("std::numeric_limits<{t0}>::max()")`.

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
An exception going back through Volt code to the C++ that called it needs C++11 (it travels as a
`std::exception_ptr`); under C++98 it stops the program.
Subclassing a C++ class (`derive`, below) needs its import under C++17 or newer.

### C++20 modules

A named module's interface (`.cppm`, `.ixx`, `.mpp`, `.cxxm`, `.ccm`) imports as a header does, on
its own in its `use`, with what it exports: an `export namespace geo { ... }`, an `export` function
or class. What it doesn't export isn't there, as for C++ code that imports it. A header (or the
module) may `import std;` (or `import std.compat;`):

```cpp
// geo.cppm
export module geo;
import std;
export namespace geo {
int twice(int x) { return 2 * x; }
std::string label(int n) { return std::format("n={}", n); }
}
```

```volt ignore
use { "geo.cppm" } as gm;

fn main() -> void {
    std::println("{} {}", gm::geo::twice(21), gm::geo::label(7)); // 42 n=7
}
```

libclang reads a module through clang's own build of it, kept in Volt's cache, and the program's
C++ is built by `$CXX` its own way: g++ (15 or newer) with `-fmodules`, clang with its precompiled
modules. The standard library's `std` module comes from the source the C++ library names in its
modules manifest (`libstdc++.modules.json`, `libc++.modules.json`), so both need a library that
ships one (GCC 15's libstdc++, LLVM 19's libc++), and reading a module needs `clang++` on `PATH`.

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

A Volt reference (`&x`, `&arr[0]`, `&s.f`, a `T&` parameter) reaches clang as the object it names,
as C++'s `f(x)` would: an `int&` parameter binds it, and a template's `S` (`S&` or `S`) deduces
`int`, not `int *`. Only when no call takes it that way is it read as its address, as `f(&x)`:
an `int*` parameter, or `template <class T> T deref(T* p)` deducing `T = int`, gets the address the
reference holds, so C++ writes through to the Volt object. A call reads all its reference arguments
one way: one wanting an `int&` beside another wanting an `int*` isn't taken, and the error is the
first reading's. So when a name has both `f(T&)` and `f(T*)`, `f(&x)` calls `f(T&)`; pass a Volt
`T*` (`val p: i32* = &x;`) to call `f(T*)`.

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
| `std::string`, `std::string_view` parameters (by value, `const&`, `&&`) | `str`: a `std::string` is a temporary made from it, so a function whose result could point into that (`const char *c_str_of(const std::string &)`) isn't declared, and a call of it per use is an error |
| a `std::string&` parameter | `std::string&`: C++ changes a copy, which the Volt string gets once the call returns (not when it throws: a `try_` form leaves the string as it was). A function whose result could point into that copy (a view, a pointer, a reference) isn't declared, and a call of it per use is an error |
| a `std::string` result | `std::string` (a copy) |
| a `std::string_view` result | `str` (the same bytes, alive as long as C++ keeps them) |
| `std::vector<T>` parameters (by value, `const&`) | `T[..]`: C++ gets a temporary vector copied from the slice, so a function whose result could point into it (`const int *data_of(const std::vector<int> &)`, a reference to an element) isn't declared, and a call of it per use is an error |
| nested `std::vector` parameters (by value, `const&`), `std::vector<std::vector<int>>` | `i32[..][..]`, to any depth, each level copied; the innermost element a number or a `char` (one of `bool`s or of a class is [per use](#calls-worked-out-per-use)) |
| a `std::vector<T>` result (`T` a plain value) | `std::vec<T>` (a copy) |
| `std::map<K, V>`, `std::unordered_map<K, V>` parameters (by value, `const&`, `&&`; the default comparator, hash and allocator, written out or not, through an alias too) | `std::map<K, V>&`: C++ gets a copy of the Volt map's entries, the Volt map unchanged; a function whose result could point into that copy (a view, a pointer, a reference) has no such form. `K` and `V` a number, `bool` or `char`, a `std::string` (from a Volt `std::string`) or a `std::vector` of numbers or `char`s (from a `std::vec`). A map C++ can also hold by handle (`std::map<int, int>`) keeps that form beside it, an overload taking a `stdcxx::map<i32, i32>`. A mutable `std::map&`, or one with another order (`std::greater<int>`), keeps its handle form, or is [per use](#calls-worked-out-per-use) when there's none |
| a `T(&)[N]` parameter, and `const T(&)[N]` | `T[N]&` (C++ writes into the Volt array), and `T[N]`; `T` a number, `bool`, pointer or a class Volt lays out |
| a parameter written as an array, `T a[N]`, `const T a[]` (a default too) | `T*`, as C++ decays it (`&arr[0]`), through an alias too; the pointer carries no length, so `N` isn't checked. A `char` one is `cstr?`, read-only even when C++'s array isn't (as a `char*` is). An array of arrays has no form yet (per use). Per use, a Volt `T*` is C++'s `T *`, and `&x` too when no call takes it as a `T &` ([per use](#calls-worked-out-per-use)) |
| a function pointer parameter, `R(*)(A...)`, and a C variadic one, `R(*)(A..., ...)` | `extern "C" fn(A...) -> R` and `extern "C" fn(A..., ...) -> R` (a fn's name), its types numbers, `bool` and pointers (a `size_t` a `usize`, a `size_t *` a `usize*`, a `const char *` parameter a `cstr` (a `cstr?` per use too) and a result a `cstr?`; `R(*)(...)`, with no fixed parameter, has no form): C++ calls the Volt fn through a cast to its own pointer type (C and C++ function types differ in the standard, but every compiler Volt builds with gives them one calling convention). A Volt fn with a reference or a C++ class in its signature has no C function pointer form: passing it, declared or [per use](#calls-worked-out-per-use), is an error naming the fn and the type |
| `std::unique_ptr<T>`, `std::shared_ptr<T>` | `stdcxx::unique_ptr<T>`, `stdcxx::shared_ptr<T>`: `get()`, and `use_count()` for the shared one; deleting one is C++'s destructor, copying a shared one adds an owner |
| operators | methods and functions named after them: `op_add` (`+`), `op_sub`, `op_mul`, `op_div`, `op_rem`, `op_eq`, `op_ne`, `op_lt`, `op_le`, `op_gt`, `op_ge`, `op_index` (`[]`), `op_call` (`()`), `op_neg` (unary `-`), `op_not`, `op_add_assign` (`+=`)... |
| `T&&` parameters | `T`: Volt hands the value over and C++ moves from it |
| a `T&&` result | `T`: a copy of what it refers to (for a class held by handle, a new object moved from it, or a borrowed handle when it can't be moved) |
| a `const` or `constexpr` constant (a number, `bool`, enum or text) in a namespace | a `val` of its value |
| a static data member `m` | `T::m()` (a copy) and `T::set_m(v)` when it can be assigned |
| a class or enum inside a class (`Outer::Inner`) | `Outer_Inner`, beside `Outer` (an unscoped enum's names stay in it: `Outer_Mode::Low`) |
| `operator T()` (explicit or not; not in a class template) | `to_T()`: `to_bool()`, `to_i32()`, `to_string()` |
| `operator=` | `assign(v)` |
| a method template | a generic method: `c.cast_to<f64>()` |
| a `std::function<R(A...)>` parameter | `fn(A...) -> R`: a closure or function; C++ calls it while the call lasts (it mustn't keep it). A class in `A...` (by value or `const&`) arrives as a borrowed handle of C++'s object (a move-only one too), good while the callback runs, or, for one Volt lays out, a copy of its struct; `R` may be a class Volt lays out |
| a `std::function` result | `stdcxx::function`: `call(...)` runs it, taking its arguments as any call's parameters (a `std::string&` too), and it's deleted with the Volt value |
| a `std::function` field | a getter, and `set_f(closure)`: the closure moves into the field, which keeps it (and deletes it once C++ is done with every copy); one capturing by reference (`\|x&\|`) is a compile error |
| a bit-field | `f()` and `set_f(v)`, on a class held by value or by handle (C++ does the bit work) |
| a namespace variable | `name()`: a reference into it (`*cpp::ns::count() = 3`), a borrowed handle for a class held by handle, or for others (a `std::string`) a copy, with `set_name(v)` |
| a constant clang can't work out (`const std::string`, `const int x = f()`) | `name()`, read through a wrapper |

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
as a `cpp_error` instead of stopping the program (a method's is `x.try_m(...)`, a constructor's
`T::try_new(...)`). Its variant says which exception it was:
`OUT_OF_RANGE`, `INVALID_ARGUMENT`, `LENGTH_ERROR`, `DOMAIN_ERROR`, `LOGIC_ERROR`, `RANGE_ERROR`,
`OVERFLOW_ERROR`, `UNDERFLOW_ERROR`, `RUNTIME_ERROR`, `BAD_ALLOC` and `BAD_CAST` for the standard
ones, one named after each class of the headers that derives from `std::exception` (the most
derived one that matches), `EXCEPTION` for any other `std::exception` and `UNKNOWN` for a thrown
value that isn't one. `last_exception()`, in the import's namespace, is what the exception said.

Calls [worked out per use](#calls-worked-out-per-use) catch the same way: `ns::try_f(...)` is
`ns::f(...)` in catch mode, as are `x.try_m(...)` and `T::try_new(...)` on a class whose members
are worked out per use. A name the header declares itself wins: when it has a `try_f` of its own,
that's what `ns::try_f` calls (the generated source says so in a comment). `@cpp` whose result type
is the import's error union catches too, mapped the same way:
`@cpp<cpp::cpp_error!i32>("ns::parse({0})", n)` gives the error or the value, and
`@cpp<cpp::cpp_error!void>(...)` an error or nothing. Its arguments are worked out before catch mode
starts, so a C++ call in one that throws stops the program as it would anywhere else, and a
`std::string&` argument is left as it was when the call throws.

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
- What crosses into an override is what the import makes of each type anywhere else: numbers,
  `bool`, enums and pointers as they are (a reference for a non-const `T&`), strings as `str` (a view
  for the call), a class Volt holds by value (a copy, or a reference for `T&`), a class held by
  handle as a handle Volt borrows for the call (a `const std::map<int, int>&` is a
  `stdcxx::map<i32, i32>&`), and the rest in their Volt forms (a `std::function` is a
  `stdcxx::function`, a `std::optional<int>` an `i32?`). A `T&&` comes as a `const T&` does. What
  comes back is any of those too, made into C++'s result type (a `std::vector<int>` from an
  `i32[..]`, a `std::map` the override made). A virtual method only C++ can override stays `C`'s
  (a comment in the generated source says so): one taking a non-const reference to text, as
  anywhere in an import ([limits](#limits)), or giving back a reference.
- `derive` is there for a class with a virtual method that isn't `final`; its destructor needn't be
  virtual. Volt deletes a derived object as what it is, its Volt value with it; C++ deleting one
  through a `C*` whose destructor isn't virtual is C++'s own undefined behavior, as for any
  subclass.
- `copy` of a derived handle copies the whole object: the `C` part with `C`'s copy constructor (a
  protected one, or an abstract class's, too) and the Volt value with its type's `copy` (a type
  that can't be copied stops the program there, saying so). An abstract class's handle has `copy`
  for that; on an object C++ made (of a C++ subclass) it stops the program, as C++ can't copy one
  through its base. `cpp_type_name()` of a derived object is the Volt type's name.

### What it costs

The C++ subclass is a template, made once for each Volt type: each override calls that type's
method directly, by its symbol, and a method the type doesn't have calls `C`'s own directly. There's
no table of function pointers and nothing checked at run time; a call from C++ costs what a virtual
call to a C++ subclass does. A type with methods of the same name for two classes (`label()` of a
`Listener` and of a `Plugin`) overrides each class's separately.

Nothing here needs RTTI, so a program built with `-fno-rtti` (`CXX="c++ -fno-rtti"`) subclasses the
same way. `derived<T>()`, `cpp_type_name()`, `copy`, deleting and the protected members know a
derived object from the handle `derive` made (or `self`, in an override), and from one C++ handed
back (`Base&` or `std::unique_ptr<Base>` results): with RTTI by `dynamic_cast`, without it by a table
of the objects `derive` made (an object made or deleted takes a lock to update it). What's C++'s own
rule: `as_Derived()` between two C++ classes is a `dynamic_cast`, and so is `cpp_type_name()` of an
object `derive` didn't make; without RTTI, either stops the program saying so.

## Limits

- What doesn't map gets a comment in the generated source. A function whose parameters or result
  only a call settles is [called per use](#calls-worked-out-per-use) instead, and so is one with a
  parameter Volt has no form for, where a call is an error (C++ can't be handed a Volt value for
  it): a `std::function` whose signature has a non-const reference in it or gives back a class
  Volt holds by handle (a `std::function` field: one taking such a class), a function pointer
  whose signature has a class, enum or reference in it (or `...`), a reference to an array of
  enums or of a class Volt holds by handle, a nested `std::vector` of `bool`s or of a class. For a
  function pointer or a `std::function`, `@cpp`'s `{&i}` passes a Volt function:
  `@cpp<i32>("ns::apply({&0}, {1})", inc, 4)`. The stub declared for such a function says why in
  its comment: `// C++: int ns::flags(const std::vector<std::vector<bool>> & v) (worked out per use:
  const std::vector<std::vector<bool>> & has no Volt form)`.
- A `std::string&` parameter is a copy C++ changes and Volt copies back once the call returns:
  given the same string twice in one call (which Volt warns of, two mutable borrows), each copy
  comes back in turn, the first parameter's last.
- A loop over a C++ range whose iterators are aligned past 8 needs its import under C++17 or newer
  (C++ holds them, with an aligned `new`). Iterators that are trivially copyable and destructible
  (the standard library's and the views' are) live in the loop's own words; the others (one holding
  a `std::shared_ptr`, a move-only one) on C++'s heap, freed however the loop ends (a `break`,
  `return` or `try` too). Under C++98/03 a range is what has `R::iterator` (`R::const_iterator`
  for a const one), `r.begin()` and `r.end()`, as the standard containers do. An exception thrown
  from `begin`, `end`, `++` or `*` stops the program, except inside a Volt function C++ called,
  where it goes back to that C++ and the heap-held iterators leak (Volt's frames are left without
  their deletes).
- A type Volt can't lay out and has no generic for (an instance of a class template that takes a
  number or a template, like `vec<3, float>` or `basic_json<>`; a lambda's own type; a coroutine's
  task type) is held by handle, named after the type (`basic_json_0`, `lambda_3`) or by the header's
  `using` alias for it (`vec3`), and its members are worked out per use: methods (`d.get("a")`),
  static functions (`json::parse(text)`), constructors (`T::new(...)`) and operators by their Volt
  names (`op_add`, `op_eq`, `op_index`, a lambda's `f.op_call(5)`). A name the class doesn't have is an error in
  clang's words. The import declares one for its own types; another library's (the standard
  library's) come through a call made per use.
  A constant whose value clang can't work out, and a variable C++ may change, are functions
  (`name()`), not `val`s.
- Generic arguments written on a method template's call parse when there's one of them, when the
  call passes nothing, or when each can only be a type (`x.get<i32>()`, `x.pair<i32, f64>()`,
  `c.convert<i32, f64>(2)`, `m.find<ns::Key, std::string>(k)`): `f(a.x < b, c > (d))` stays two
  comparisons. Otherwise they come from the call's arguments, as a generic function's can.
- A C++ exception that reaches Volt through a function's plain form (or an `@cpp` whose result
  isn't a `cpp_error` union) stops the program, like a panic; its `try_` form returns it as an
  error. In Volt code C++ called (a closure passed as a
  `std::function`, an override of a virtual method), it goes back to that C++ instead, rethrown with
  its own type, so a `catch` there gets it; the Volt frames between are left without running their
  deletes (the C++ copy of a `std::string&` made for a call in such a frame among them, which
  leaks; the Volt string stays as it was). A Volt panic ends the program, in a callback too.
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
- A class whose destructor isn't public can't be owned by Volt: it has no `T::new`, no `{}` and no
  `delete`. One C++ hands out (a factory's `T*` or `T&` result) is a borrowed handle whose methods
  and fields work as any handle's, and it's freed C++'s way (the class's own `destroy(&s)`), never
  by Volt.
- A class whose alignment comes from members Volt can't show (`alignas(32)`) is held by handle,
  C++'s aligned `new` and `delete` making and freeing it. That needs its import under C++17 or
  newer when it's aligned past 8; under an older standard it's left out, and its comment says so.

[C++ coverage](/volt-bootstrap/interop/cpp-coverage/) sums up what comes through, the libraries
it's tested against, and what can't map, with the way around each.

Runnable examples: [Volt calls C++](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/cpp) and [C++ calls Volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/cpp).
