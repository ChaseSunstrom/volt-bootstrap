---
title: Templates
description: Generic functions and types, specialization, constant parameters and packs.
sidebar:
  order: 8
---

Volt's generics are templates, like C++'s: each set of generic arguments makes its own copy of
the function or type, compiled as if written by hand. There are no boxed values and no runtime
dispatch.

## Generic functions

The generic parameters go in `<...>` on the line before the declaration. `T: type` takes a type.
Arguments are usually inferred from the call; `f<T>(...)` gives them explicitly.

```volt
use std::io;

<T: type>
fn max(a: T, b: T) -> T {
    if (a > b) {
        return a;
    }
    return b;
}

fn main() -> void {
    std::println("{} {} {}", max(3, 9), max(2.5, 1.0), max<u8>(200, 100));
}
// expect: 9 2.5 200
```

A template's body is checked for each set of arguments it's used with, so it can use anything the
argument supports: `max` works for every type with `>`. Using it with a type that doesn't have
`>` reports the error at that use, and names each template instance on the way to it, back to
the call in code that isn't a template: sorting a struct with no `cmp` points into std, and at
your `sort` call. To state the requirements up front, bound the parameter with a
[trait](/volt-bootstrap/guide/traits/).

## Generic types

Structs, enums and error sets take generic parameters the same way, with defaults.

```volt
use std::io;

<T: type>
struct pair {
    first: T;
    second: T;
}

<T: type>
attach fn swapped(this: pair<T>) -> pair<T> {
    return { first: this.second, second: this.first };
}

<T: type>
enum maybe {
    SOME: T,
    NONE,
}

fn main() -> void {
    val p: pair<str> = { first: "a", second: "b" };
    val q = p.swapped();
    val m: maybe<i32> = .SOME(4);
    std::println("{} {} {}", q.first, q.second, m);
}
// expect: b a SOME(4)
```

## Constant parameters

A generic parameter can be a value known at compile time instead of a type: `N: usize`,
`C: i32 = 3`. Array lengths are the usual use.

```volt
use std::io;

<T: type, N: i32>
fn sum(xs: T[N]) -> T {
    var s: T = 0;
    for (x) in xs {
        s += x;
    }
    return s;
}

fn main() -> void {
    val a: i64[4] = { 1, 2, 3, 4 };
    val b: f64[2] = { 0.5, 0.25 };
    std::println("{} {}", sum(a), sum(b));
}
// expect: 10 0.75
```

## Specialization

A declaration with `<...>` after its name covers particular arguments and is used instead of the
generic one. A full specialization names concrete types; a partial one names a shape, like "any
reference".

```volt
use std::io;

<T: type>
fn describe(v: T) -> str { return "a value"; }
fn describe<bool>(v: bool) -> str { return "a bool"; }

<T: type>
struct holder { value: T; }

<T: type>
struct holder<T&> { value: T*; }            // for every holder<T&>: store a nullable pointer

fn main() -> void {
    val h: holder<i32&> = { value: null };
    std::println("{} {} {}", describe(1), describe(true), h.value == null);
}
// expect: a value a bool true
```

## Packs

`Args: type...` takes any number of types, and `args: Args...` the matching values. A
`comptime for` over a pack unrolls: each iteration has its own type.

```volt
use std::io;

<Args: type...>
fn show_all(args: Args...) -> void {
    comptime for (a) in args {
        std::print("[{}] ", a);
    }
    std::println("");
}

fn main() -> void {
    show_all(1, "two", 3.5, true);
    show_all();
}
// expect: [1] [two] [3.5] [true]
// expect:
```

## Methods on every type

An attached function whose receiver is a generic parameter attaches to every type. std uses this
for `T::new(value)`, which boxes any value.

```volt
use std::io;

<T: type>
attach fn describe_twice(this: T) -> void {
    std::println("{} {}", this, this);
}

fn main() -> void {
    42.describe_twice();
    "ok".describe_twice();
}
// expect: 42 42
// expect: ok ok
```

## Return-type overloads

Overloads that differ only in the return type (see [Functions](/volt-bootstrap/guide/functions/))
work for templates too. std's `T::new` has one returning a `T` and one returning a box, and the
context picks.
