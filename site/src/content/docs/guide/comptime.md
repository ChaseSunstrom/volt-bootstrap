---
title: Comptime
description: Code that runs in the compiler, types as values, @typeinfo, @cfg and attributes.
sidebar:
  order: 11
---

Volt can run ordinary code while compiling. The results become constants, types or whole branches
of the program.

## comptime functions

A `comptime fn` always runs in the compiler; its calls are replaced by their results.

```volt
use std::io;

comptime fn fib(n: i32) -> i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    for (i) in 0..n {
        val t = a + b;
        a = b;
        b = t;
    }
    return a;
}

comptime fn squares() -> i32[5] {
    var out: i32[5] = { 0, 0, 0, 0, 0 };
    for (i) in 0..5 {
        out[i] = i * i;
    }
    return out;
}

val TABLE_LEN: usize = fib(10);

fn main() -> void {
    var table: u8[TABLE_LEN];
    std::println("{} {} {}", fib(50), squares(), table.len);
}
// expect: 12586269025 { 0, 1, 4, 9, 16 } 55
```

A comptime error (overflow, an out-of-bounds index, a runaway loop) is a compile error.

## Types as values

`type` is a type, so a comptime function can compute one, and a variable can hold one.

```volt
use std::io;

comptime fn counter_type(big: bool) -> type {
    if (big) {
        return i64;
    }
    return i8;
}

fn main() -> void {
    val x: counter_type(true) = 5000000000;
    std::println(x);
}
// expect: 5000000000
```

## comptime if, match and for

Inside any function, `comptime if`, `comptime match` and `comptime for` are decided in the
compiler. A branch that isn't taken isn't even checked; a `comptime for` unrolls.

```volt
use std::io;

<C: i32>
fn classify() -> str {
    comptime match (C) {
        0 => { return "zero"; },
        c if c > 100 => { return "big"; },
        default => { return "other"; },
    }
}

<N: i32>
fn wide() -> i64 {
    comptime var T: type;
    comptime if (N > 0) {
        T = i64;
    } else {
        T = i8;
    }
    var v: T = 100;
    return v as i64;
}

fn main() -> void {
    std::println("{} {} {}", classify<0>(), classify<500>(), wide<1>());
    comptime for (i) in 0..3 {
        std::print(i);
    }
    std::println("");
}
// expect: zero big 100
// expect: 012
```

## Reflection: @typeinfo and @typeof

`@typeof(expr)` is an expression's type. `@typeinfo(T)` describes a type at compile time: its name,
size, alignment, kind (with fields, variants, element types) and more.

```volt
use std::io;

struct point {
    x: i32;
    y: i64;
}

<T: type>
fn name_of(v: T) -> str {
    return @typeinfo(T).short_name;
}

fn main() -> void {
    val p: point = { x: 1, y: 2 };
    std::println("{} {} {}", name_of(p), name_of(1.5), @typeinfo(@typeof(p)).size.value);
    std::println(@typeinfo(std::mem::box<i32>).canonical_name);
}
// expect: point f64 16
// expect: std::mem::box<i32, std::mem::default_allocator>
```

`@compile_error("message")` fails compilation when it's reached, for custom checks in templates.

## Configuration: @cfg

`@cfg("key")` is true when `--cfg key` (or `key=...`) was given; `@cfg("key", "value")` when
`--cfg key=value` was. bolt passes a package's enabled features as `feature=NAME`. A branch that's
off isn't checked, so it can use a dependency that isn't there.

```volt
use std::io;
// flags: --cfg feature=fast --cfg level=3

fn speed() -> str {
    comptime if (@cfg("feature", "fast")) {
        return "fast";
    }
    return "normal";
}

fn main() -> void {
    std::println("{} {} {}", speed(), @cfg("level"), @cfg("level", "2"));
}
// expect: fast true false
```

`--cfg pkg:key=value` sets a key for package `pkg`'s files only.

### The target

Three keys describe the platform being built for. Every package sees them without any `--cfg`:

| Key | Values |
| --- | --- |
| `os` | `linux`, `macos`, `windows`, `freebsd` |
| `arch` | `x86_64`, `aarch64`, `riscv64`, `x86`, `arm` |
| `pointer_bits` | `64` or `32` |

A library uses them to pick per-platform code, and the branches for other platforms aren't checked.
At run time, `std::process::os()` and `std::process::arch()` give the same names.

The keys describe the host. Passing one with `--cfg`, such as `--cfg os=windows`, replaces the host's
value for every package. `voltc check --cfg os=windows` then checks another platform's branches on
this machine. Only checking makes sense this way: a build still runs on the host, and
`std::process::os()` still reports the host.

```volt
use std::io;

fn line_end() -> str {
    comptime if (@cfg("os", "windows")) {
        return "\r\n";
    }
    return "\n";
}

fn main() -> void {
    std::print("{} on {}{}", std::process::os() == "windows", @cfg("pointer_bits", "64"), line_end());
}
// expect: false on true
```

## Attributes

`@attributes([...])` before a declaration attaches compile-time attributes. Only known ones are
accepted, so a typo is an error.

| Attribute | Meaning |
| --- | --- |
| `@inline`, `@noinline` | inlining hints |
| `@opt(n)` | optimization level for this function (0 to 3) |
| `@section(".name")` | put the function in a section |
| `@align(n)` | alignment |
| `@deprecated("use x")` | warn where it's used |
| `@intrinsic("name")` | a compiler builtin or runtime function (for std-like libraries) |
| `@owns("field")` | this struct owns what the field points at, like `box` |

```volt
use std::io;

@attributes([@deprecated("use total")])
fn sum(a: i32, b: i32) -> i32 {
    return a + b;
}

@attributes([@inline])
fn total(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> void {
    std::println("{}", total(1, 2));
}
// expect: 3
```
