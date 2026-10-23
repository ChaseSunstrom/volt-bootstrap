---
title: C++ coverage
description: What of a C++ library Volt can call, what it's tested against, and what can't map (with the way around each).
sidebar:
  order: 2
---

[C++](/volt-bootstrap/interop/cpp/) covers how a header becomes Volt declarations. This page is the
summary of how far that goes: what comes through, the real libraries it's tested against, and what
doesn't map, with the way around each.

## What comes through

| C++ | Volt |
| --- | --- |
| namespaces (an inline one, a library's ABI version, is its parent's) | namespaces |
| functions, overloads, default arguments | functions, overloads, one overload per default left out |
| overloads Volt can't tell apart (`long` / `long long`, `char` / `signed char`, `get()` / `get() const`) | the first declared by its name, the others named for their parameter types (`which_long_long`, `get_const`) |
| function templates (type parameters; the defaulted ones C++ fills in) | generic functions |
| a trivially copyable class | a struct with C++'s layout |
| any other class (an over-aligned one too, under C++17 or newer) | a handle to the object C++ allocates |
| class templates Volt can lay out (public fields, no bases), their number parameters too (`fixed<class T, int N>`) | generic structs (`fixed<T, N: i32>`, its `T data[N]` a `T[N]`) |
| other class templates (private fields, bases, virtual methods, or a field of a type with no Volt form such as `std::mutex`; one only declared, its partial specializations the definitions, like glm's `vec`) | generic handles (`ns::box<i32>`, `glm::vec<3, f32>`), made by `{}` or `T::new(...)`, their public fields getters and `set_` methods, their other members worked out per use |
| a class template's specializations (an explicit `template <> struct S<void>`, a partial `S<T*>`) | the instances clang makes from one (`ns::box<void>`, `ns::box<i32*>`) are handles, made by `T::new(...)`, their members worked out per use (a field read gives a copy of it); the primary's instances keep their generic struct's layout, an explicit instantiation's (`template struct S<long>;`) too. Clang picks, as in C++ |
| function template specializations (`template <> int f<int>(int)`, a member's), and what a library adds to namespace `std` (`std::hash<Key>`, a `swap` found by argument-dependent lookup) | C++ picks them at each call. A `std` container of the library's type comes from a `use` naming both headers (`use cpp { "unordered_map", "lib.hpp" } as cpp;`): an instance sees its own `use`'s headers, as a C++ file sees what it includes |
| an instance of a class template that takes a template (`basic_json<>`), or a number when a function's signature names it (glm's `vec<3, float>`); a lambda's own type; a coroutine-style task; and the `using` alias naming one | a handle to the object (`{}` makes one with its default constructor), its members worked out per use: methods, static functions, `T::new(...)`, operators by their Volt names (`op_call` is `()`) |
| a class or enum inside a class | `Outer_Inner` |
| constructors, destructors, copy constructors | `T::new(...)`, the `delete` and `copy` hooks; a class whose destructor isn't public has none, its objects borrowed from a factory and freed by the class's own `destroy` |
| methods, static methods, method templates, operators | methods, `T::f(...)`, generic methods, `op_add`, `to_T()`, `assign(v)` |
| public fields (bit-fields too), static data members | fields, in a class held by value; getters and `set_` methods for bit-fields, static members and a handle's fields (a `std::function` field's takes a closure and keeps it) |
| namespace variables, constants clang can't work out | `name()`: a reference into a variable (or a copy and `set_name(v)`), a constant read through a wrapper |
| `const`/`constexpr` constants | `val`s |
| enums (scoped or not) | enums (an unscoped one's names also constants beside it) |
| virtual methods | overridden by name in an `attach C -> T` block (private ones too; a later overload by a suffixed name, `draw_double`; `std::string&` parameters and reference results); `C::derive` makes the subclass (no RTTI; C++ calls each override directly, not through a table of Volt functions) |
| public bases (one reached by two paths, by its path), `dynamic_cast`, `typeid` | `as_Base()`, `as_B1_A()`, `as_Derived()`, `cpp_type_name()` |
| `T*`, `T&`, `T&&`, `const T&`, `std::unique_ptr<T>`, `std::shared_ptr<T>` of a class held by handle | borrowed handles (`T?` for a pointer), owning ones for a `unique_ptr`; a `shared_ptr` is a handle whose `get()` borrows |
| exceptions | `try_` forms (for every function that can throw, and calls worked out per use) returning a `cpp_error` naming the exception, and `@cpp<cpp_error!R>(...)`; one thrown under a Volt callback rethrown to the C++ that called it, with its own type |
| `std::string`, `std::string_view`, `std::vector`, `std::unique_ptr`, `std::shared_ptr`, `std::function` | `str`/`std::string`, `T[..]`/`std::vec<T>`, `stdcxx::` handles, `fn(...)` values (a class in a `std::function`'s signature a borrowed handle or a copy) |
| `std::string&`, `T(&)[N]`, function pointer parameters | `std::string&` (C++'s changes copied back, unless it threw), `T[N]&` (`T[N]` for a `const` one; a class held by handle or a `std::string` through a copy, its changes copied back), `extern "C" fn(...)` |
| a type by what it can do: optional-like, tuple-like, contiguous, variant-like (`std::optional`, `std::pair`, `std::tuple`, `std::array`, `std::span`, `std::variant`, any library's own) | `T?`, tuples (under C++98, which has no `std::tuple_size`, a `std::pair` is one too), `T[N]`, `T[..]`/`std::vec<T>`, an enum to `match` on |
| a range (`begin(r)`, `end(r)`: containers, views; under C++98, `R::iterator` with `r.begin()`, `r.end()`), its iterators any kind (move-only, holding a `shared_ptr`) | `for (x) in r` |
| the standard library's own headers (`use cpp { "map" }`) | their declarations under `stdcxx`, class templates as generic handles (`stdcxx::map<K, V>`) |
| C++20 modules: a named module's interface (`use { "geo.cppm" }`), a header doing `import std;` or `import std.compat;` | what the module exports, as a header's declarations ([modules](/volt-bootstrap/interop/cpp/#c20-modules)) |

A library found on the include path (`use cpp { "re2/re2.h" }`, `use { "nlohmann/json.hpp" }`)
brings in the declarations of the files under its own directory (`re2/`, `nlohmann/`), not the rest
of the system's headers or the C++ standard library's. A standard header named on its own (`map`,
`optional`) brings in the files implementing it.

## Tested against

The interop tests import these and run what maps, on both backends:

- **re2** (`re2/re2.h`, linked with `--cc -lre2`): `RE2::new(pattern)`, `ok()`, `pattern()`,
  `NumberOfCapturingGroups()`.
- **nlohmann::json** (`nlohmann/json.hpp`): the header imports cleanly through its inline ABI
  namespace; its free functions and enums (`detail::value_t`, `detail::op_lt`) run, and `json`
  (`basic_json<>`, a class template with private state) is held by handle: `{}` is a null json,
  and `json::parse(text)`, `size()` and `dump()` are worked out per use.
- **The C++ standard library**: `map`, `unordered_map`, `set`, `deque` and `list` by their headers'
  names, looped over with `for`; `optional`, `pair`, `tuple`, `array`, `span`, `string_view` and
  `variant` in a header's signatures, both ways; a C++20 view (`iota | transform`) looped over.
- **glm** (`glm/glm.hpp`): its generic functions over numbers (`glm::abs`, `glm::min`,
  `glm::clamp`), and its vectors by their template (`glm::vec<3, f32>::new(1.0, 2.0, 2.0)`,
  `glm::length(&v)`).
- **A framework sample** with pure virtual interfaces, an event bus calling its listeners by
  priority and a plugin registry: the listeners and plugins are Volt types, made with `derive`.

Only the wrappers the program reaches are compiled, so a header's function that needs a library the
program doesn't link costs nothing until it's called. Whatever a header has that doesn't map gets a
comment in the generated source (`VOLT_SHOW_CPP=1` prints it), and the rest still works. What Volt can't declare ahead (variadic and non-type templates,
`auto` results, constrained templates, function-like macros) is
[called per use](/volt-bootstrap/interop/cpp/#calls-worked-out-per-use): clang works out each call.

## What can't

| C++ | Why | The way around it |
| --- | --- | --- |
| class templates with template template parameters (`basic_json`'s), or with a number parameter of a type other than an integer or `bool` (an enum, a pointer), as generics | Volt's generic structs take types and integer or `bool` values, not templates (functions with them are [called per use](/volt-bootstrap/interop/cpp/#calls-worked-out-per-use)) | an instance: the header's alias for one (`using json = basic_json<>;`), or one a function gives back, is a handle, made by `{}` or `json::new(...)`, its members worked out per use |
| a parameter of a function pointer whose signature has a class, enum or reference (`int (*)(const Shape &)`), or of a `std::function` with a non-const reference in its signature or a class held by handle as its result | Volt has no form for it (a function pointer over numbers and pointers is an `extern "C" fn`; a `std::function` over classes takes a closure) | `@cpp`'s `{&i}` passes a Volt function by its symbol: `@cpp<i32>("ns::apply({&0}, {1})", inc, 4)` |

A library's own declarations in namespace `std` (its `std::hash<T>` specializations, `swap`
overloads) aren't Volt names: Volt's own `std` stays what `std::` means, and C++ finds them at
each call.
