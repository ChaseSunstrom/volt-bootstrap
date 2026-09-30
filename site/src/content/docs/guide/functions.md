---
title: Functions
description: Declaring functions, parameters and defaults, overloading, and entry points.
sidebar:
  order: 2
---

A function names its parameters' types and its return type. `-> void` returns nothing.

```volt
use std::io;

fn area(w: f64, h: f64) -> f64 {
    return w * h;
}

fn greet(name: str) -> void {
    std::println("hi {}", name);
}

fn main() -> void {
    greet("volt");
    std::println("{}", area(2.0, 4.5));
}
// expect: hi volt
// expect: 9
```

## Parameters

Parameters can't be reassigned. `var` in front of one gives the function a mutable copy. A default
value lets a call leave the parameter out.

```volt
use std::io;

fn countdown(var n: i32, step: i32 = 1) -> void {
    while (n > 0) {
        std::print("{} ", n);
        n -= step;
    }
    std::println("");
}

fn main() -> void {
    countdown(3);
    countdown(10, 4);
}
// expect: 3 2 1
// expect: 10 6 2
```

A parameter of a type that owns something (a `std::string`, a `vec`) takes ownership of the
argument: the caller's value moves in. Take a reference, `T&`, to borrow it instead. See
[Ownership](/volt-bootstrap/guide/ownership/).

## Overloading

Several functions can share a name when their parameters differ. The call picks the one whose
parameter types fit the arguments best, and an ambiguous call is an error.

```volt
use std::io;

fn show(x: i32) -> void { std::println("int {}", x); }
fn show(x: f64) -> void { std::println("float {}", x); }
fn show(x: str, times: i32) -> void {
    for (i) in 0..times {
        std::print("{} ", x);
    }
    std::println("");
}

fn main() -> void {
    show(1);
    show(2.5);
    show("hey", 2);
}
// expect: int 1
// expect: float 2.5
// expect: hey hey
```

Functions can even differ only in their return type; then the call needs a type from its context.

```volt
use std::io;

fn parse_default() -> i32 { return 7; }
fn parse_default() -> str { return "seven"; }

fn main() -> void {
    val n: i32 = parse_default();
    val s: str = parse_default();
    std::println("{} {}", n, s);
}
// expect: 7 seven
```

## never

A function that never returns (it exits, panics or loops forever) returns `never`. A `never` value
fits wherever any type is expected.

```volt
use std::io;

fn fail(msg: str) -> never {
    std::eprintln("fatal: {}", msg);
    std::process::exit(2);
}

fn half(n: i32) -> i32 {
    if (n % 2 != 0) {
        fail("odd");
    }
    return n / 2;
}

fn main() -> void {
    std::println("{}", half(8));
}
// expect: 4
```

## main

`main` is where a program starts. It returns `void`, an integer (the exit code) or an error union:
an error reaching the end of main prints `error: NAME` and exits with 1. Arguments come from
`std::process::arg(i)`.

```volt
use std::io;

fn main() -> i32 {
    val program = std::process::arg(0) ?? "?";
    std::println("{} args", std::process::arg_count());
    return 0;
}
```

## Methods and more

- Functions attached to a type are methods: [Structs and methods](/volt-bootstrap/guide/structs/).
- `<T: type>` functions are templates: [Templates](/volt-bootstrap/guide/templates/).
- Function values and closures: [Closures](/volt-bootstrap/guide/closures/).
- `comptime fn` runs while compiling: [Comptime](/volt-bootstrap/guide/comptime/).
- `extern "C" fn` and `export fn` meet C: [C interop](/volt-bootstrap/interop/c/).
