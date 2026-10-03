---
title: Swift
description: Calling ordinary Swift files from Volt by importing them like a header, and what each Swift declaration becomes.
sidebar:
  order: 3
---

## Volt calls Swift

Runnable example: [Volt calls Swift](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/swift).
The other way, Swift calling a Volt library, is in [Other languages](/volt-bootstrap/interop/other-languages/#swift).

One line imports Swift files, as one imports a C header:

```volt ignore
use std::io;
use { "shapes.swift" } as shapes;          // or several: use { "a.swift", "b.swift" } as x;

fn main() -> !void {
    val p: shapes::Point = { x: 3.0, y: 4.0 };       // a struct of plain properties, by value
    std::println("{}", p.length());                  // a computed property is a method
    val t = shapes::Tally::new();                    // a class: init(...) is new(...)
    t.add(2);
    std::println("{}", try shapes::divide(7, 2));    // throws: an error
}
```

The Swift is ordinary: nothing in it is marked for Volt, and `internal` declarations count as well
as `public` ones (only `private` and `fileprivate` ones are left out). voltc runs `bolt import`,
which reads the files' declarations, writes a shim of `@_cdecl` functions that call them, and
builds both into one Swift module with `swiftc -emit-library`. It caches the result and redoes it
when a file changes. It works the same with `voltc run main.volt` and in a bolt package. bolt reads
`$SWIFTC` for the compiler, else `swiftc` on the PATH.

| Swift | Volt |
| --- | --- |
| `func f(label x: T)` at the top level | `fn f(x: T)`: arguments by position, the shim adds the labels |
| `Int`, `UInt` | `isize`, `usize` |
| `Int8`…`UInt64`, `Double`, `Float`, `Bool` | `i8`…`u64`, `f64`, `f32`, `bool` |
| `String` | `str` in, `std::string` out (a copy) |
| `[T]` of numbers or strings | `T[..]`, `str[..]` in; `std::vec<T>`, `std::vec<std::string>` out |
| `T?` | `T?` |
| `throws` | `swift_error!T`; the error, as Swift describes it, is in `swift_error::ERROR` |
| `inout S` of a struct | `S&`: what Swift writes comes back |
| a struct whose stored properties are all numbers, `Bool`s, such structs or enums, with no `init` of its own | a Volt struct with those fields, passed by value |
| a class | an owned handle; `copy` shares the object, as a second Swift reference does |
| any other struct, or an enum with associated values | an owned handle; `copy` copies the value |
| an enum without associated values | a Volt enum; an `Int` enum keeps its raw values when they're literals |
| `init(...)`, and the memberwise and empty inits Swift writes itself | `T::new(...)`; a second `T::new_<its first label>(...)` |
| a method, `mutating` or not, a `static func` | a method; `T::f(...)` |
| a computed property, or a class's stored one | a method without arguments: `p.length()` |
| a top-level `let` of a number, `Bool` or string | a `val` |

Generic and `async` functions, protocols, actors, nested types, closures, a second function of the
same name (an overload), what's under `#if` (swiftc decides which branch is in), and declarations
marked `@MainActor` (or another global actor) or `@available(*, unavailable)` aren't callable from
Volt; they're left out, listed in a comment of the generated declarations (`VOLT_SHOW_IMPORT=1 voltc check main.volt` prints them). A Swift name that is
a Volt keyword gets a `_` after it (`move` is `move_`). The program links the module as a shared
library from bolt's cache, and the Swift runtime from the toolchain.
