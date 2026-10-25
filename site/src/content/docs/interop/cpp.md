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
| overloads Volt can't tell apart (`long` and `long long` are both `i64` where `long` is 64 bits (not on Windows), `char` is `signed char`'s or `unsigned char`'s twin depending on the target (signed on x86-64, unsigned on arm64 Linux), so which overload collides depends on the target, a `const` method's `this` is a non-`const` one's) | the first declared keeps the name; each other one is named for its parameters' C++ types, after the namespace's own names: `which_long_long(x)`, `letter_char(c)` (when `char` comes after the other two), `T::new_long_long(n)`, `get_const()` (words joined by `_`, `*` as `ptr`, `&` as `ref`, `&&` as `rref`; when only its qualifiers differ, `const`, `lref`, `rref` or `nonconst` instead: `get_nonconst()` after a `get() const`), its default-argument forms too, and calls exactly that overload. A name a real declaration (in any block of the namespace) or another such name has is not used: the form gets the first free name, its words then `_2`, `_3`... (`which_long_long_2`, `get_nonconst_2`), the declaration order deciding who gets which |
| a method qualified `&&` on a class held by handle | an attached function taking `this` by value: the handle is consumed (using it afterwards is a use after move), and C++ moves from the object, or from a copy of it when the handle only borrows it (`as_Base()`). A class that can be neither copied nor moved has no copy to make: an owned handle's object runs the method, and a borrowed handle stops the program with `can't call Q::m (an && method) through a borrowed handle: Q can't be copied`; an inherited `&&` method (worked out per use) the same, its borrowed-handle stop saying `can't call an && method through a borrowed handle: Q can't be copied`; its `const &&` methods, and an abstract class's `&&` ones, run in place on the object, borrowed or not, the handle kept. On a class template's instance (worked out per use) the same, for a method only an rvalue can call (when `&` and `&&` overloads share the name, the call is the `&` one's), and `derive`'s `base_m()` and protected forms leave it out with a comment: their object is the Volt subclass's |
| functions, function templates | functions, generic functions: `ns::biggest<i32>(a, b)`. A template's `S&` or `const S&` parameter (`S` one of its type parameters) is a Volt reference, `s: S&`: `ns::wrap(&x)` lends `x` to the call and deduces `S` as what it names, and `ns::wrap(x)` is an error (it would move `x` in). `S` and `S&&` take a value: `ns::take(move x)`, or `ns::take(copy x)` to keep `x`; an `S` given a reference to a value that owns no memory (`ns::echo(&n)`, or a reference parameter passed on) deduces `S` as what it names and takes a copy, as C++'s `echo(n)` does (a reference to a closure is lent); an `S&&` given a reference (`ns::take(&x)`, or a reference parameter passed on) is an error, since C++ would move from the caller's value. Beside an `S&` or `const S&` overload, `f(&x)` calls that one, and the `S` or `S&&` overload is named for its parameters' forms (`ns::f_rref(move x)`; a `const S&` beside an `S&` is `ns::f_const_ref(&x)`); each calls exactly its own overload, so of a function (or method) pair `f(S&)` / `f(S)` (or `const S&` / `S`), `ns::f(&x)` (or `obj.f(&x)`) runs the reference one and `ns::f_value(x)` the value one, though C++'s `f<int>(x)` would be ambiguous (such a pair has no forms that leave out defaulted arguments; a class template's pair is worked out per use, where C++ finds `obj.f(x)` ambiguous as its own call would be). A class's static method is `ns::C::f` only: beside a function `f` of its namespace, `ns::f` is the function. A plain Volt fn's name passed where a template deduces its parameter (`template <class F> int apply(F f)`) is its C function pointer: `ns::apply(seven)` instantiates `apply<int32_t (*)(void)>`; a fn value held in a variable or a closure has no C++ form, and the error says to pass a plain fn's name. A class template's member is different: its `T&` parameter is a Volt reference, `x: T&` (`k.bump(&n)` lends `n` and C++'s write to it is seen; `k.bump(n)` is an error naming the parameter), and its `const T&` takes a value, `x: T`, which C++ only reads (`Vec2<f32>::new(1.0, 2.0)` for `Vec2(const T&, const T&)`). A generic handle's member, [worked out per use](#calls-worked-out-per-use), takes `&n` for its `T&` the same way |
| a Volt `std::string` for a function template's parameter (`template <class S> void wrap(S&)`) | a C++ `std::string`: `ns::wrap(&text)` instantiates `wrap<std::string>`. For `S&` C++ changes a copy, which the Volt string gets once the call returns (not when it throws: a `try_` form leaves it as it was); for `const S&` and `S` the copy is made from the text and nothing comes back. Overloads resolve as C++'s for `f(s)`: a string Volt may change (a `var`, or a reference to one) runs `S&` over `const S&`, and a forwarding `S&&` changes it; a `val` or a `str` runs `const S&`, in `@cpp` and through the template's Volt generic alike. A function passing its own reference parameter on through `@cpp` changes what it was lent when C++ takes it by a non-const reference (the `S&` of an `S&` / `const S&` pair, a deduced `S`) or calls a non-const method on it (`{0}.append("!")`, `{0} += 'x'`), so lending that function a `val` is an error; a `const S&` or `std::string_view` parameter only reads. C++ never writes into a string Volt can't change: a `val` (or a temporary) for a template that takes only `S&` is an error, as C++ refuses it (`'k' is a val, and wrap changes it`). `S*` takes a `std::string*` (C++ gets a pointer to a copy, written back as for `S&`), and `S` as the result comes back as a Volt `std::string`; `S` in another type is an error, so a `std::vector<S>` takes a `str[..]` of the strings' text (`ns::count_all(texts[..])`), not a slice of `std::string`s |
| class templates | generic structs: `ns::Box<f64>`; one with private fields, bases, virtual methods, a field with no Volt form or a layout from `alignas`, `aligned` or `packed` (on the class, a field, or an aligned typedef a field's type names; below C++17 one an alignment attribute aligns, whatever its value, or one holding such a type is left out, as `new` there doesn't align it, and making an instance its type argument aligns past what `new` aligns, 16 on a 64-bit target, doesn't build, its error naming `volt_cpp_needs_cxx17_aligned_new`) is a generic handle (`ns::box<i32>`), its public fields getters and `set_` methods, its other members worked out per use. A number parameter (`int`, `unsigned`, `long`, `short`, `char`, `std::size_t`, `bool`, an enum) is a generic value: `template <class T, int N> struct fixed` is `fixed<T, N: i32>`, used as `ns::fixed<i32, 3>`, an enum one its integer type (`template <Mode M> struct Tag` is `Tag<M: i32>`, `ns::Tag<1>` for `Mode::B`, which C++ gets as `static_cast<Mode>(1)`), a `char` one `i8` or `u8` as the target's `char` is; a pointer one has none (a Volt generic value is a number, and C++ wants an object's address there), its `T data[N]` a `T[N]`. An instance one of the template's specializations makes (`template <> struct box<void>`, a partial `box<T*>`), as clang picks it, is a handle instead (`ns::box<void>::new(1.5)`), its members worked out per use (`b.scale` reads a copy of the field) |
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
A `std::pair` reads as a tuple under C++98 too (a `std::map`'s entries `kv.0` and `kv.1`).
A class C++98 declares an assignment for that can't be defined (a `const` or reference field, or a
field or base with one) can't be assigned there either, as from C++11 on: no `set_` for a field of
it, no `T(&)[N]` form that assigns it.
An exception going back through Volt code to the C++ that called it needs C++11 (it travels as a
`std::exception_ptr`); under C++98 it stops the program.
Subclassing a C++ class (`derive`, below) needs its import under C++11 or newer.

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
reference holds, so C++ writes through to the Volt object. A call first reads all its reference
arguments one way; when that fails, each is handed over as something that converts to both `T&` and
`T*`, so one wanting an `int&` beside another wanting an `int*` works. So when a name has both `f(T&)` and `f(T*)`, `f(&x)` calls `f(T&)`; pass a Volt
`T*` (`val p: i32* = &x;`) to call `f(T*)`.

A Volt value that isn't a class (a number, a `bool`, a pointer, an enum) reaches clang as a
temporary: `const int&`, `int&&` and `int` take it, and an `int&` doesn't, since C++ would change only
a copy. `f(n)` for an `f(int&)` is an error naming the parameter; pass `&n`.

A Volt type C++ has no type for still goes to a template that takes anything (`template <class T>
T echo(T)`, `template <class... A>`, a declared generic's `T` too):

| Volt | in C++ |
|---|---|
| a Volt struct, a tuple, `T?` (not a pointer's), an enum with payloads, `f16`, `f128` | a struct of its bytes, `volt_m_N` (its size and alignment): C++ copies it and gives it back (`echo(p)` is `p`; an explicit template argument, `size_of<point>()` or `same<point>(p, q)`, names the same struct as a parameter type; a call made per use whose result is one gives back the Volt value, a pointer to one a `T*`, even when only an explicit template argument names it, `zero<point>()`; a reference to one, `global<point>()`, comes back as a copy, as does any reference result of a call whose reference parameter took one passed by value, `h.pick(p)`, since it could be into C++'s copy), but can't read its fields or do arithmetic on it. One with a `delete` (a `std::vec`, a `std::string` inside) is an error: C++ would copy what it owns |
| a closure, a `fn(A...) -> R` value | `std::function<R(A...)>` calling it (good while the call is: C++ mustn't keep it), `A` and `R` numbers, `bool`, pointers or enums; `@cpp` text lends it, and a template's per-use fn takes it as any Volt fn does (a closure owning what it captured moves there: pass `&c` to keep it) |
| a pointer to one of those | `volt_m_N *` (a slice of them has no form per use yet) |

A reference to a mirrored value is read as its address (`f(&p)` calls `f(T*)`), since C++'s `T&`
would change only a copy.

Each mirror checks its size and alignment against the type as the target's C compiler lays it out,
which is how both backends lay it out. Where the two differ (i386 aligns `i64` and `f64` to 4), the
C++ step fails with `Volt's point: the mirror's size or alignment isn't the type's C layout on this
target`, rather than the program copying the wrong bytes. `f16`, `f128`, `i128` and vectors are
checked as the C compiler's own types (`_Float16`, `__float128` or a binary128 `long double`,
`__int128`, GNU C's vectors); where it has none (no `__int128` on i386), as their bytes.

## The standard library, operators and exceptions

Signatures that use the standard library's strings, vectors and smart pointers map to Volt's:

```cpp
// ledger.hpp
namespace ledger {
struct Money {
    long long cents;
    Money operator+(const Money& o) const;
    bool operator<(const Money& o) const;
};
long long cents(std::string_view s);          // throws std::invalid_argument
Money parse(std::string_view s);
std::string format(Money m);
std::vector<long long> running(const std::vector<long long>& xs);
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
| `std::string`, `std::string_view` parameters (by value, `const&`, `&&`) | `str`: a `std::string` is a temporary made from it, with the same bytes. A function giving back a `std::string_view` into it (`std::string_view trim(const std::string &)`) is declared: the view it gives points at the same place in the `str` instead, which the caller keeps alive. One whose result could point into it otherwise (`const char *c_str_of(const std::string &)`, as a `str` has no NUL after it) isn't declared, and a call of it per use is an error |
| a `std::string&` parameter | `std::string&`: C++ changes a copy, which the Volt string gets once the call returns (not when it throws: a `try_` form leaves the string as it was). One Volt string given to two `std::string&` parameters, or to one and a `const std::string&` (as `s.as_str()`, the whole string), is one C++ string, as C++ would pass it: a write through one shows through the other. A function whose result could point into that copy (a view, a pointer, a reference) isn't declared, and a call of it per use is an error |
| a `std::string` result | `std::string` (a copy) |
| a `std::string_view` result | `str` (the same bytes, alive as long as C++ keeps them) |
| `std::vector<T>` parameters (by value, `const&`) | `T[..]`: C++ gets a temporary vector copied from the slice (of a class Volt holds by handle, a slice of handles whose objects are copied in; of `std::string`s, a `str[..]`, each made from its text). Of numbers, enums, pointers or classes Volt lays out, the vector has the same bytes as the slice: a function giving back a pointer or a reference to an element (`const int *data_of(const std::vector<int> &)`, `const pt &leftmost(const std::vector<pt> &)`) is declared, its result pointing at the same place in the slice instead, which the caller keeps alive. One whose result could point into the vector otherwise (a vector of `bool`s or of classes held by handle, a view of the vector itself) isn't declared, and a call of it per use (a template's too) is an error |
| nested `std::vector` parameters (by value, `const&`), `std::vector<std::vector<int>>` | `i32[..][..]`, to any depth, each level copied; the innermost element a number, a `bool`, a `char` or a POD class Volt lays out (one of enums, pointers or a class held by handle is [per use](#calls-worked-out-per-use)) |
| a `std::vector<T>` result (`T` a plain value) | `std::vec<T>` (a copy) |
| `std::map<K, V>`, `std::unordered_map<K, V>` parameters (by value, `const&`, `&&`, `&`; any comparator, hash, equality and allocator the standard has or the headers declare that can be made from nothing, `std::greater<int>` or a comparator class, through an alias too) | `std::map<K, V>&`: C++ gets a copy of the Volt map's entries in a map of the parameter's own type (its own order), the Volt map unchanged; for a mutable `std::map&` the Volt map gets the copy's entries back once the call returns (cleared, then each put: C++'s inserts, changes and erases; not when C++ threw, as a `std::string&`; C++11 on). A function whose result could point into that copy (a view, a pointer, a reference) has no such form. `K` and `V` a number, `bool`, `char` or enum (a key hashed by its value: the import attaches `hash` to the enum), a `std::string` (from a Volt `std::string`) or a `std::vector` of numbers or `char`s (from a `std::vec`; not for a mutable map), and `V` a class Volt lays out. Each takes the map by handle too, an overload beside it: a `stdcxx::map<i32, i32>` for a `std::map<int, int>`, and for a map `stdcxx` can't spell (a `std::string` key, `std::vector<bool>` values) a handle of its own, the one a function returning that map gives, so a map C++ made goes back to C++ (`val m = ns::make();` then `ns::total(&m)`). A comparator that can't be made from nothing takes only the handle |
| a `T(&)[N]` parameter, and `const T(&)[N]` | `T[N]&` (C++ writes into the Volt array), and `T[N]`; `T` a number, `bool`, pointer, enum (one whose Volt enum has its C++ size) or a class Volt lays out. `T` a class Volt holds by handle: `T[N]&` either way; `T` a `std::string`: `std::string[N]&`, and `str[N]`; a `const std::string_view(&)[N]`: `str[N]` (C++ views the Volt strings for the call). Those C++ gets as an array copied from the Volt elements, which a non-`const` one's changes go back into once the call returns (not when it throws: a `try_` form leaves them as they were). Each element is its own copy: an array holding one object's handle twice, or one array given to two parameters, gets separate C++ copies, the last copy back winning. A class that can't be copied (or, for a non-`const` one, assigned; below C++11, for a `const` one too) has no such form. `N` is the Volt array type's, so another length is a type error |
| a `T(&)[N]` result, `const` or not (`int (&nums())[3]`) | `T[N]&`, into C++'s array (Volt has no const), as a reference result is; `T` an enum whose Volt enum has its C++ size too. `T` a class Volt holds by handle: `T[N]`, handles borrowing C++'s elements (good while the array is) |
| a function pointer result, `R(*)(A...)` | `extern "C" fn(A...) -> R`, called as any Volt fn (`cpp::pick()(4)`), its types those a function pointer parameter takes (numbers, `bool`, pointers, enums, a class Volt lays out and references to those): `double (*pick_area())(const Shape&)` gives `extern "C" fn(cpp::Shape&) -> f64`, called as `cpp::pick_area()(&s)` |
| a parameter written as an array, `T a[N]`, `const T a[]` (a default too) | `T*`, as C++ decays it (`&arr[0]`), through an alias too; the pointer carries no length, so `N` isn't checked. A `char` one is `cstr?`, read-only even when C++'s array isn't (as a `char*` is). An array of arrays has no form yet (per use). Per use, a Volt `T*` is C++'s `T *`, and `&x` too when no call takes it as a `T &` ([per use](#calls-worked-out-per-use)) |
| a function pointer parameter, `R(*)(A...)`, and a C variadic one, `R(*)(A..., ...)` | `extern "C" fn(A...) -> R` and `extern "C" fn(A..., ...) -> R` (a fn's name), its types numbers, `bool`, pointers and enums (a `size_t` a `usize`, a `size_t *` a `usize*`, a `const char *` parameter a `cstr` (a `cstr?` per use too) and a result a `cstr?`; `R(*)(...)`, with no fixed parameter, has no form), a `T&` or `const T&` of one of those or of a class Volt lays out (a Volt `T&`), and such a class by value when it's POD: `void each(const std::vector<Shape>&, double (*)(const Shape&))` takes `fn area(s: cpp::Shape&) -> f64` as `cpp::each(v.items(), area)`. C++ calls the Volt fn through a cast to its own pointer type (C and C++ function types differ in the standard, but every compiler Volt builds with gives them one calling convention, and passes a reference as it passes a pointer). [Per use](#calls-worked-out-per-use) (a template's), such a fn crosses as an object that converts to the function pointer type the call wants when the signatures match (a `const T&` takes a `T&`, an enum its integer type, a number another of its size and kind; C++11 on), and a template's deduced `F` takes it as it is, its call calling the fn. A function pointer whose signature has a class Volt holds by handle (whose Volt value isn't the C++ object), a `T&&` or a `std::string&` is a `comptime` parameter taking a fn's name: `int apply(int (*f)(const Name&), const char*)` is `cpp::apply(size_of, "abc")` for `fn size_of(n: cpp::Name) -> i32`, the fn getting a borrowed handle (good while the call is; a `T&&` read as a `const T&`, a `std::string&` a Volt `std::string&` whose changes go back, as a `std::function`'s closure gets them). C++ calls a thunk made for that fn, so it may keep the pointer and call it later; a fn value held in a variable has no symbol for one, and passing it is an error naming the parameter. Per use, such a fn (or one taking a slice or a fn value) has no form: passing it is an error naming the fn and the type |
| `std::unique_ptr<T>`, `std::shared_ptr<T>` | `stdcxx::unique_ptr<T>`, `stdcxx::shared_ptr<T>`: `get()`, and `use_count()` for the shared one; deleting one is C++'s destructor, copying a shared one adds an owner |
| operators | methods and functions named after them: `op_add` (`+`), `op_sub`, `op_mul`, `op_div`, `op_rem`, `op_eq`, `op_ne`, `op_lt`, `op_le`, `op_gt`, `op_ge`, `op_index` (`[]`), `op_call` (`()`), `op_neg` (unary `-`), `op_not`, `op_add_assign` (`+=`)... |
| `T&&` parameters | `T`: Volt hands the value over and C++ moves from it |
| a `T&&` result | `T`: a copy of what it refers to (for a class held by handle, a new object moved from it, or a borrowed handle when it can't be moved) |
| a `const` or `constexpr` constant (a number, `bool`, enum or text) in a namespace | a `val` of its value |
| a static data member `m` | `T::m()` (a copy) and `T::set_m(v)` when it can be assigned |
| a class or enum inside a class (`Outer::Inner`) | `Outer_Inner`, beside `Outer` (an unscoped enum's names stay in it: `Outer_Mode::Low`) |
| `operator T()` (explicit or not) | `to_T()`: `to_bool()`, `to_i32()`, `to_string()`; in a class template the name follows the template's spelling, so `template <class T> struct Box { operator T() const; }` gives `to_T()` on every instance |
| `operator=` | `assign(v)` |
| a method template | a generic method: `c.cast_to<f64>()`; a class template's (`Bag<T>::one<U>`) is worked out per use, each call's template arguments deduced or given |
| a `std::function<R(A...)>` parameter | `fn(A...) -> R`: a closure or function; by reference, C++ calls it while the call lasts (it mustn't keep it). Taken by value (by a function with no overload of its name), where C++ may keep it, the parameter is generic over the closure, which moves in: the `std::function` owns it, and copies of it share it, deleted with the last (`b.on_click(\|move word\| (n: i32) -> i32 { ... })`; one capturing by reference is a compile error); a plain fn is kept as a closure calling it, and a fn value is lent. A class in `A...` (by value, `&`, `const&` or `&&`) arrives as a borrowed handle of C++'s object (a move-only one too), good while the callback runs, or, for one Volt lays out, a copy of its struct (by `&`, a Volt `T&` to C++'s object). A `std::string&` is a Volt `std::string&` holding a copy, which goes back into C++'s string once the closure returns (`ns::shout("hi", \|\| (s: std::string&) -> void { s.append("!"); })`); a non-const `T&` of a number, enum or pointer is a Volt `T&` to C++'s; a `T&&` is read as a `const T&` is. `R` may be a class Volt lays out, or one it holds by handle: the closure's handle (`\|\| (k: i32) -> cpp::Shape { return cpp::Shape::new("tri", k); }`) is moved into the object C++ gets, or copied when it only borrows one; a reference result has no form |
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
  `Widget`), and so do private ones (or ones inherited through a base that isn't public): a struct
  that doesn't override a private one that isn't pure leaves `C`'s own in place (its subclass has no
  override of it then, as C++ couldn't call `C`'s own), and it has no `base_` method.
- Overloads of a virtual method are overridden by their own names: the first found (the class's own
  first, then its bases') keeps the name, the later ones get their parameters' C++ types as words, as other overloads Volt can't
  tell apart do (`draw(int)` and `draw(double)` are `draw` and `draw_double`; a `const` one gets
  `_const` too, and a non-`const` twin of a `const` one with no parameters is `_nonconst`). One
  whose name that makes is a virtual method's already stays `C`'s. A method qualified `&` or `&&`
  is overridden as any other (an `&&` one beside an `&` or unqualified twin is `name_rvalue`; a type
  without it gets `C`'s own, called on the object as an rvalue). A virtual operator is overridden by
  its Volt name (`operator==` by `op_eq`, `operator()` by `op_call`). A C variadic one
  (`int log(const char *fmt, ...)`) is overridden with a last `va: void*`, the address of the
  call's `va_list` (read with `@cpp<i32>("va_arg(*(va_list *){0}, int)", va)`); a type without it
  keeps `C`'s own, which C++ can't hand the arguments to otherwise (one whose last named parameter
  is a reference, or that has none, stays `C`'s: `va_start` can't start there).
- What crosses into an override is what the import makes of each type anywhere else: numbers,
  `bool`, enums and pointers as they are (a reference for a non-const `T&`), strings as `str` (a view
  for the call), a class Volt holds by value (a copy, or a reference for `T&`), a class held by
  handle as a handle Volt borrows for the call (a `const std::map<int, int>&` is a
  `stdcxx::map<i32, i32>&`), and the rest in their Volt forms (a `std::function` is a
  `stdcxx::function`, a `std::optional<int>` an `i32?`). A `T&&` comes as a `const T&` does. What
  comes back is any of those too, made into C++'s result type (a `std::vector<int>` from an
  `i32[..]`, a `std::map` the override made). A `std::string&` is a Volt `std::string&` holding a
  copy, which goes back into C++'s string once the override returns. A reference result (`int&`, a
  laid-out class's `Pt&`) is a Volt reference the override gives back (`return &this.n;`), and for
  a class held by handle a reference to a handle (`return &this.item;`), whose object C++ gets; as
  C++'s own rule is, it has to refer to something that outlives the call (the Volt value, the C++
  object). A parameter whose type has no Volt form (a pointer to member, say) comes as a `void*`
  to C++'s argument, which the override can hand back to C++ through `@cpp`. A virtual method whose
  result has no Volt form here (a reference to a `std::string`, a pointer to member) stays `C`'s,
  and a comment in the generated source says so; when it's pure, Volt types still derive from `C`,
  and C++'s call of it throws a `std::logic_error` saying why (a `noexcept` one stops the program).
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
  it): a `std::function` giving back a reference (a `std::function` field: one taking a class
  Volt holds by handle or a `std::string&`, or giving back such a class), a C variadic function pointer
  whose signature has a class Volt holds by handle or a `T&&` in it (below C++11, any such function pointer), a reference to an array of
  an enum whose Volt enum has another size, a nested `std::vector` of enums, pointers or a class
  held by handle. For a
  function pointer or a `std::function`, `@cpp`'s `{&i}` passes a Volt function:
  `@cpp<i32>("ns::apply({&0}, {1})", inc, 4)`. The stub declared for such a function says why in
  its comment: `// C++: int ns::flags(const std::vector<std::vector<Mode>> & v) (worked out per use:
  const std::vector<std::vector<Mode>> & has no Volt form)`.
- A Volt struct, tuple, `T?`, enum with payloads, `f16` or `f128` handed to C++ per use is its
  bytes: a template can copy it, not read it (`x.f` or `x * 2` on one is clang's error), and a
  `std::optional`, `std::tuple` or `std::variant` parameter worked out per use doesn't take one
  (a declared one does).
- A `std::string&` parameter is a copy C++ changes and Volt copies back once the call returns.
  The same Volt string given to two of them in one call is one C++ copy, so C++ sees one string,
  as it would (`both(&s, &s)` with `a += "x"; b += "y";` leaves `s` ending in `xy`).
- A Volt type deriving from a C++ class can't override its variadic virtual methods (`...`), its
  `&&`-qualified ones or its operators: they stay C++'s (and when one of them is pure, Volt types
  can't derive from the class). An override's `std::string&` is a copy too, which C++'s string
  gets once the override returns.
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
  template, like `basic_json<>`, or a number in a function's signature, like a `vec<3, float>`
  result; a lambda's own type; a coroutine's task type) is held by handle, named after the type (`basic_json_0`, `lambda_3`) or by the header's
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
  pointer, and the object stays where C++ made it. A handle made by `{}` or `T::new(...)` is never
  empty: `{}` makes the object with its default constructor (`new T()`), and for a class that can't
  be made from nothing `{}` is a compile error that says to use `T::new(...)`. (Its `cpp` and
  `borrowed` fields are the importer's: set by hand, as `{ cpp: null, borrowed: true }`, they make
  an empty handle, and using one stops the program.)
- A class clang says can be copied but whose copy doesn't compile (one holding a
  `std::vector<std::unique_ptr<T>>`: the vector's copy constructor is declared for any element)
  has no `copy`: the import tries each class's copy, and one that fails isn't copyable.
- A class whose destructor isn't public can't be owned by Volt: it has no `T::new`, no `{}` and no
  `delete`. One C++ hands out (a factory's `T*` or `T&` result) is a borrowed handle whose methods
  and fields work as any handle's, and it's freed C++'s way (the class's own `destroy(&s)`), never
  by Volt.
- A class whose layout comes from members Volt can't show (`alignas(32)`, a field of an aligned
  typedef that puts it past or below its type's own alignment, or a packed field) is held by handle,
  C++'s aligned `new` and `delete` making and freeing it. That needs its import under C++17 or
  newer when it's aligned past 8; under an older standard it's left out, and its comment says so
  (a function taking one gets no wrapper either; the rest of the header imports). One held by
  handle for another reason (a `std::string` member) is declared, but making one aligned past what
  `new` aligns there (16 on a 64-bit target) doesn't build, its error naming
  `volt_cpp_needs_cxx17_aligned_new`.
  So a packed C++ class is a handle (its fields read and written through accessors), unlike a
  packed C struct, which a C import keeps as a value with each field at C's offset.

[C++ coverage](/volt-bootstrap/interop/cpp-coverage/) sums up what comes through, the libraries
it's tested against, and what can't map, with the way around each.

Runnable examples: [Volt calls C++](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/cpp) and [C++ calls Volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/cpp).
