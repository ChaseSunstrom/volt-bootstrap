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
| function templates (type parameters; the defaulted ones C++ fills in) | generic functions |
| a trivially copyable class | a struct with C++'s layout |
| any other class | a handle to the object C++ allocates |
| class templates Volt can lay out (public fields, no bases) | generic structs |
| an instance Volt can't lay out (a class template with private fields, bases or virtual methods, such as `basic_json`; a lambda's own type; a coroutine-style task), and the `using` alias naming it | a handle to the object (`{}` makes one with its default constructor), its members worked out per use: methods, static functions, `T::new(...)`, operators by their Volt names (`op_call` is `()`) |
| a class or enum inside a class | `Outer_Inner` |
| constructors, destructors, copy constructors | `T::new(...)`, the `delete` and `copy` hooks |
| methods, static methods, method templates, operators | methods, `T::f(...)`, generic methods, `op_add`, `to_T()`, `assign(v)` |
| public fields (bit-fields too), static data members | getters and `set_` methods (a `std::function` field's takes a closure and keeps it) |
| namespace variables, constants clang can't work out | `name()`: a reference into a variable (or a copy and `set_name(v)`), a constant read through a wrapper |
| `const`/`constexpr` constants | `val`s |
| enums (scoped or not) | enums |
| virtual methods | overridden by name in an `attach C -> T` block; `C::derive` makes the subclass (no RTTI; C++ calls each override directly, not through a table of Volt functions) |
| public bases (one reached by two paths, by its path), `dynamic_cast`, `typeid` | `as_Base()`, `as_B1_A()`, `as_Derived()`, `cpp_type_name()` |
| `T*`, `T&`, `T&&`, `const T&`, `std::unique_ptr<T>`, `std::shared_ptr<T>` of a class held by handle | borrowed handles (`T?` for a pointer), owning ones for a `unique_ptr`; a `shared_ptr` is a handle whose `get()` borrows |
| exceptions | `try_` forms (for every function that can throw) returning a `cpp_error` naming the exception; one thrown under a Volt callback rethrown to the C++ that called it, with its own type |
| `std::string`, `std::string_view`, `std::vector`, `std::unique_ptr`, `std::shared_ptr`, `std::function` | `str`/`std::string`, `T[..]`/`std::vec<T>`, `stdcxx::` handles, `fn(...)` values |
| a type by what it can do: optional-like, tuple-like, contiguous, variant-like (`std::optional`, `std::pair`, `std::tuple`, `std::array`, `std::span`, `std::variant`, any library's own) | `T?`, tuples, `T[N]`, `T[..]`/`std::vec<T>`, an enum to `match` on |
| a range (`begin(r)`, `end(r)`: containers, views) | `for (x) in r` |
| the standard library's own headers (`use cpp { "map" }`) | their declarations under `stdcxx`, class templates as generic handles (`stdcxx::map<K, V>`) |

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
  `glm::clamp`).
- **A framework sample** with pure virtual interfaces, an event bus calling its listeners by
  priority and a plugin registry: the listeners and plugins are Volt types, made with `derive`.

Every wrapper the import writes is compiled with the program, called or not. So whatever a header
has that doesn't map is left out with a comment in the generated source (`VOLT_SHOW_CPP=1` prints
it), and the rest still works. What Volt can't declare ahead (variadic and non-type templates,
`auto` results, constrained templates, function-like macros) is
[called per use](/volt-bootstrap/interop/cpp/#calls-worked-out-per-use): clang works out each call.

## What can't

| C++ | Why | The way around it |
| --- | --- | --- |
| class templates with non-type or template template parameters (glm's `vec<3, float>`) | Volt's generic structs take types (functions with them are [called per use](/volt-bootstrap/interop/cpp/#calls-worked-out-per-use)) | a `using vec3 = glm::vec3;` with wrapper functions over it |
| C++20 modules (`import std;`) | the import reads headers | the headers the module is built from |

Explicit specializations (`template <> struct S<void>`) and what a library adds to namespace `std`
(`std::hash<T>` specializations, `swap` overloads) are left out on purpose: the template, and Volt's
own `std`, are what Volt sees.
