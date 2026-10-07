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
| a class or enum inside a class | `Outer_Inner` |
| constructors, destructors, copy constructors | `T::new(...)`, the `delete` and `copy` hooks |
| methods, static methods, method templates, operators | methods, `T::f(...)`, generic methods, `op_add`, `to_T()`, `assign(v)` |
| public fields, static data members | getters and `set_` methods |
| `const`/`constexpr` constants | `val`s |
| enums (scoped or not) | enums |
| virtual methods | overridden by name in an `attach C -> T` block; `C::derive` makes the subclass (no RTTI, no call through a table) |
| public bases, `dynamic_cast`, `typeid` | `as_Base()`, `as_Derived()`, `cpp_type_name()` |
| exceptions | `try_` forms returning a `cpp_error` naming the exception |
| `std::string`, `std::string_view`, `std::vector`, `std::unique_ptr`, `std::shared_ptr`, `std::function` | `str`/`std::string`, `T[..]`/`std::vec<T>`, `stdcxx::` handles, `fn(...)` values |

A library found on the include path (`use cpp { "re2/re2.h" }`, `use { "nlohmann/json.hpp" }`)
brings in the declarations of the files under its own directory (`re2/`, `nlohmann/`), not the rest
of the system's headers or the C++ standard library's.

## Tested against

The interop tests import these and run what maps, on both backends:

- **re2** (`re2/re2.h`, linked with `--cc -lre2`): `RE2::new(pattern)`, `ok()`, `pattern()`,
  `NumberOfCapturingGroups()`.
- **nlohmann::json** (`nlohmann/json.hpp`): the header imports cleanly through its inline ABI
  namespace, and its free functions and enums (`detail::value_t`, `detail::op_lt`) run.
  `basic_json` itself is a class template with private state, so it isn't one of the ones Volt
  can use; see below.
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
| a class template with private fields, bases or virtual methods (`basic_json`) | Volt lays out a class template's instances itself, and can't see what's private | wrapper functions over one instance (`nlohmann::json`) in a header of your own |
| a lambda's own type | it has no name to declare (a function's `auto` result is called per use) | take or return a `std::function` |
| C++20 modules (`import std;`) | the import reads headers | the headers the module is built from |
| coroutines (`co_await`, `co_return`) | their results are coroutine handles and promise types | a wrapper that runs the coroutine and returns its result |
| pointers to classes held by handle (`T*`), non-const `T&` results of them | Volt can't tell who owns the object | a reference parameter (`T&`), or `as_Base()` and `as_Derived()` |
| bit-fields | a Volt field can't be part of a byte | a getter and setter in C++ |
| a `std::function` field's setter | a Volt closure stored in C++ would outlive the call | a C++ method that takes it and copies what it needs |
| standard library types other than the ones above (`std::map`, `std::optional`...) | each needs its own mapping | a wrapper returning one of the ones above |

Explicit specializations (`template <> struct S<void>`) and what a library adds to namespace `std`
(`std::hash<T>` specializations, `swap` overloads) are left out on purpose: the template, and Volt's
own `std`, are what Volt sees.
