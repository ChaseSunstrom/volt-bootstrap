---
title: Kotlin
description: Calling ordinary Kotlin files from Volt (Kotlin/Native) by importing them like a header, and what each Kotlin declaration becomes.
sidebar:
  order: 3
---

## Volt calls Kotlin

The other way, Kotlin calling a Volt library, is in
[Other languages](/volt-bootstrap/interop/other-languages/#kotlinnative).

One line imports Kotlin files, as one imports a C header:

```volt ignore
use std::io;
use { "shapes.kt" } as shapes;             // or several: use { "a.kt", "b.kt" } as x;

fn main() -> void {
    val p: shapes::Point = { x: 3.0, y: 4.0 };       // a data class of plain vals, by value
    std::println("{}", p.length());
    val t = shapes::Tally::new();                    // a class: its constructor is new(...)
    t.add(2);
    std::println("{}", t.total());                   // a property is a method
    val r = shapes::try_parse("x");                  // what it throws, as an error
    if (r.err) {
        std::println("{}", r.err);
    }
}
```

The Kotlin is ordinary: nothing in it is marked for Volt, and `internal` declarations count as well
as `public` ones (only `private` and `protected` ones are left out). voltc runs `bolt import`, which
reads the files' declarations, writes a shim of `@CName` functions that call them, and builds both
with `kotlinc-native -produce static` into one archive with the Kotlin/Native runtime. It caches the
result and redoes it when a file (or the compiler) changes. It works the same with
`voltc run main.volt` and in a bolt package. bolt reads `$KOTLINC_NATIVE` for the compiler, else
`kotlinc-native` on the PATH.

| Kotlin | Volt |
| --- | --- |
| `fun f(x: T): R` at the top level | `fn f(x: T) -> R`; a default argument is passed like any other |
| `Int`, `Long`, `Short`, `Byte` | `i32`, `i64`, `i16`, `i8` |
| `UInt`…`UByte`, `Double`, `Float`, `Boolean` | `u32`…`u8`, `f64`, `f32`, `bool` |
| `String` | `str` in, `std::string` out (a copy) |
| `List<T>` (`Collection`, `Iterable`) of numbers or strings | `T[..]`, `str[..]` in; `std::vec<T>`, `std::vec<std::string>` out |
| `T?` | `T?` |
| an exception it throws | the plain form stops the program with it; `try_f(...)` gives it as `kotlin_error::PANIC`, its `toString()` |
| a `data class` whose constructor's parameters are all `val`s of numbers, `Boolean`s, such classes or enum classes, with no other stored property | a Volt struct with those fields, passed by value |
| any other class, and an `object` | an owned handle; `copy` shares the object, as a second Kotlin reference does |
| an `enum class` | a Volt enum, by its entries' order |
| the primary constructor, or the `T()` Kotlin writes itself | `T::new(...)`; a secondary `constructor` `T::new_<its first parameter>(...)` |
| a member `fun` | a method |
| an `object`'s or a `companion object`'s `fun` | `T::f(...)` |
| a property (`val`, `var`, or a constructor's `val`) | a method without arguments: `t.total()` |
| a top-level `const val` or `val` of a number, `Boolean` or string | a `val` |

Generic, `suspend` and extension functions, `vararg` parameters, interfaces, nested types,
typealiases, a function whose result type isn't written (`fun f() = ...`) and a second function of
the same name (an overload) aren't callable from Volt; they're left out, listed in a comment of the
generated declarations (`VOLT_SHOW_IMPORT=1 voltc check main.volt` prints them). A Kotlin name
that is a Volt keyword gets a `_` after it (`move` is `move_`). The program links the archive from
bolt's cache with `-lpthread -ldl -lm -lstdc++`; two Kotlin imports in one program share one
runtime.
