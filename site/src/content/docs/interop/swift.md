---
title: Swift
description: Calling ordinary Swift files from Volt by importing them like a header, what each Swift declaration becomes, and the shapes Swift takes calling Volt.
sidebar:
  order: 3
---

## Volt calls Swift

Runnable example: [Volt calls Swift](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/swift).
The other way, Swift calling a Volt library, is in [Other languages](/volt-bootstrap/interop/other-languages/#swift)
and [below](#swift-calls-volt).

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

## Swift calls Volt

`voltc bindings --lang swift` writes Swift over a Volt library's C header; how to build with it is
under [Other languages](/volt-bootstrap/interop/other-languages/#swift).

### Every shape

Swift takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape):

- **Owned values as parameters.** A `std::string` parameter takes a `String` (Volt copies it); an
  export struct by value takes its class, which gives its handle up. A call can't give one object
  twice, give away or close one a running call holds, or give one Volt only lent a callback: each
  is a failed precondition, checked before anything is given.
- **Traits.** A trait is a class protocol: an object conforming to it is lent (`s: shape&`) or
  given (`s: shape`: Volt keeps it until it's done with it). A Volt value of the trait is a
  `volt_shape`, which conforms too; `close()` or `deinit` frees it.
- **Callbacks taking and giving text and handles.** A callback is a closure taking and giving
  `String`s and classes (one Volt lends is the callback's until it returns). An `E!T` callback
  (or trait method) `throws`: the error set's enum gives Volt that error, and any other error
  comes out of the Volt call, which `throws` it (Volt gets the set's first error meanwhile; when a
  given object's method throws during a call that can't throw, the error is dropped).
- **Closures given back** are classes called like functions, freed by `close()` or `deinit`.
- **Names.** `close()` frees an object, so a Volt method or trait fn named `close` is `close_()`
  in Swift; a parameter named like a type gets a `_` after it.
- **Lists, and text and handles in slices and optionals.** A `std::vec<T>` comes back as a `[T]`
  (`String`s, or classes the caller owns) and goes in from one (giving its handles up); `[String]`
  and arrays of a class (lent) go in for `std::string[..]` and a slice of an export struct. An
  optional text or handle is a `String?` or a `T?`, and a slice of optionals an `inout [T?]`.

For a library `shapes` with a trait `shape` (`area`, `name`, `grow`), `describe(s: shape&) ->
std::string`, `make_square(side: f64) -> shape`, `doubler() -> fn(i32) -> i32` and
`try_twice(f: fn(i32) -> bank_error!i32, x: i32) -> bank_error!i32`:

```swift
final class Circle: shape {
    var r: Double
    init(_ r: Double) { self.r = r }
    func area() -> Double { 3 * r * r }
    func name() -> String { "circle" }
    func grow(_ by: Double) { r += by }
}

print(describe(Circle(1)))                    // circle of area 3
let sq = make_square(2)                       // a volt_shape
print(sq.name(), sq.area())                   // square 4.0
let d = doubler()
print(d(21))                                  // 42
do {
    _ = try try_twice({ x in
        if x > 5 {
            throw bank_error.OVERDRAWN
        }
        return x * 2
    }, 4)
} catch bank_error.OVERDRAWN {
    print("overdrawn")
}
```
