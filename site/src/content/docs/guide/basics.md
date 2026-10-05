---
title: Basics
description: Variables, types, literals, operators, control flow, arrays, slices and tuples.
sidebar:
  order: 1
---

## Variables

`val` declares a name whose value can't change: it can't be reassigned, and nothing changes it
through a reference either
([references to a val](/volt-bootstrap/guide/references/#references-to-a-val)). `var` declares one
that can. The type comes from the value, or is written after a colon. A `var` declared without a
value starts at zero.

```volt
use std::io;

fn main() -> void {
    val answer = 42;          // i32: an integer literal's default type
    val ratio = 0.5;          // f64
    var count: u8 = 1;
    count += 2;
    var buffer: u8[4];        // zeroed
    buffer[0] = count;
    std::println("{} {} {} {}", answer, ratio, count, buffer[0]);
}
// expect: 42 0.5 3 3
```

Function parameters are `val`s too; `fn f(var x: i32)` gives the function its own mutable copy.

## Types

| Type | What it is |
| --- | --- |
| `i8` `i16` `i32` `i64` `i128`, `isize` | signed integers |
| `u8` `u16` `u32` `u64` `u128`, `usize` | unsigned integers (`usize` for sizes and indexes) |
| `f16` `f32` `f64` `f128` | floating point |
| `bool` | `true` or `false` |
| `str` | UTF-8 text: a pointer and a length, not null-terminated |
| `cstr` | a null-terminated C string (string literals convert to it) |
| `void`, `never` | no value; never returns (`@panic`, `exit`, an endless loop) |
| `T[N]`, `T[]` | an array; `T[]` takes its length from the initializer |
| `T[..]` | a slice: a view into an array (pointer and length) |
| `(A, B)` | a tuple |
| `T?` | an [optional](/volt-bootstrap/guide/errors/#optionals) |
| `E!T` | an [error union](/volt-bootstrap/guide/errors/) |
| `T&`, `T*` | a [reference and a pointer](/volt-bootstrap/guide/references/) |
| `fn(A) -> R` | a [function value](/volt-bootstrap/guide/closures/) |

### Type aliases

`type name = T;` gives a type another name. It's the same type, not a new one: a `meters` is an
`f64` wherever an `f64` goes. An alias can be generic, taking its arguments where it's used, and
in a package it's the package's own unless marked `public`, like any other declaration.

```volt
use std::io;

type meters = f64;
<T: type>
type list = std::vec<T>;

fn total(a: meters, b: meters) -> meters {
    return a + b;
}

fn main() -> void {
    var xs: list<i32> = {};
    xs.push(3);
    std::println("{} {}", total(1.5, 2.0), xs.len);
}
// expect: 3.5 1
```

An alias can't be defined in terms of itself (`type a = b; type b = a;` is an error).

## Literals

```volt
use std::io;

fn main() -> void {
    val big = 1_000_000;
    val mask = 0xFF;
    val bits = 0b1010;
    val perms = 0o755;
    val sci = 1.25e1;
    val letter = 'a';         // a u8
    val text = "tab\there";   // escapes: \n \t \r \0 \\ \" \' \xNN \u{...}
    std::println("{} {} {} {} {} {}", big, mask, bits, perms, sci, letter);
    std::println("{}", text);
}
// expect: 1000000 255 10 493 12.5 97
// expect: tab	here
```

### Multi-line and raw strings

`"""` starts a string on the next line, and a `"""` on a line of its own ends it. The closing
quotes' indentation comes off every line, so the text sits indented with the code around it; the
lines are joined with `\n`, without one after the last (leave an empty line before the closing
quotes for that). Escapes work as in `"..."`, and `\"""` puts three quotes in. `r"..."` and
`r"""..."""` are raw: a backslash is just a backslash.

```volt
use std::io;

fn main() -> void {
    val page = """
        <ul>
          <li>one</li>
        </ul>
        """;
    std::println(page);
    std::println(r"C:\temp\new");
    std::println(r"""
        \d+\.\d+ "quoted"
        """);
}
// expect: <ul>
// expect:   <li>one</li>
// expect: </ul>
// expect: C:\temp\new
// expect: \d+\.\d+ "quoted"
```

## Operators

The arithmetic, comparison, logical and bitwise operators are C's. What's different:

- Integer overflow **traps** in debug builds and wraps in `--release` builds. `+%`, `-%` and `*%`
  always wrap, for hashes and checksums.
- `x++` and `x--` are statements, not expressions.
- `x as T` converts only when nothing can be lost (widening an integer, integer to float, `T&` to
  `T*`); anything else is a compile error. `@cast<T>(x)` converts anything to anything, unchecked.
- `a ?? b` is the value of optional `a`, or `b` when it's null.
- `==` and `!=` on a struct (or an enum with payloads) call its `eq(other)`: one it attaches, like
  `std::string`'s, or a [derived](/volt-bootstrap/guide/comptime/#derive) one. A type without one
  can't be compared. `eq` takes one side by reference, so both sides can't be temporaries
  (`make() == make()`: store one in a variable first).
- `a..b` and `a..=b` are ranges (exclusive and inclusive).
- Operands and arguments are evaluated left to right. `place = value` evaluates the value first,
  then the place; `place += value` evaluates the place first, since it reads it.
- A statement that only computes a value (`x + 1;`, `a == b;`) is an error, since it does nothing.
  When it looks like a missing `=`, the message says so: `x + 1;` suggests `+=`, `a == b;`
  suggests `=`.

```volt
use std::io;

fn main() -> void {
    val small: u8 = 200;
    val wide = small as i32;                  // fine: every u8 fits in an i32
    val back = @cast<u8>(wide + 100);         // unchecked: 300 becomes 44
    val hash = 4000000000 *% 3;               // wraps on purpose
    std::println("{} {} {}", wide, back, hash > 0);
}
// expect: 200 44 true
```

## Control flow

`if` and `while` take a `bool` in parentheses, and their bodies always have braces.

```volt
use std::io;

fn main() -> void {
    var n = 27;
    var steps = 0;
    while (n != 1) {
        if (n % 2 == 0) {
            n /= 2;
        } else {
            n = 3 * n + 1;
        }
        steps++;
    }
    std::println("{}", steps);
}
// expect: 111
```

### for

`for` walks a range, an array or a slice. A second name gets the index. `for (x&)` binds each
element by reference instead of copying it, so the loop can change it.

```volt
use std::io;

fn main() -> void {
    var scores: i32[] = { 70, 85, 90 };
    for (s&) in scores {
        *s += 5;
    }
    for (s, i) in scores {
        std::print("{}:{} ", i, s);
    }
    std::println("");
    for (i) in 0..=3 {
        std::print("{} ", i);
    }
    std::println("");
}
// expect: 0:75 1:90 2:95
// expect: 0 1 2 3
```

### Iterators

A type that attaches `next(this: T&) -> X?` is an iterator: `for` calls `next` until it returns
`null`, binding each value. `next` can return a pointer, `X*`, instead: each element then binds as
an `X&`, so the loop can change what it points at, and collections iterate without copying. An iterator in a `var` is advanced by the loop; a `val` one is copied
first, and a temporary (like `m.iter()`) lives until the loop ends. The index, labels, `break`, `continue` and accumulators
work as they do for arrays.

```volt
use std::io;

struct countdown {
    n: i32;
}

attach fn next(this: countdown&) -> i32? {
    if (this.n == 0) {
        return null;
    }
    this.n -= 1;
    return this.n + 1;
}

fn main() -> void {
    val c: countdown = { n: 3 };
    for (x, i) in c {
        std::print("{}{}", x, i);
    }
    std::println("");
}
// expect: 302112
```

### loop, labels and break values

`loop` repeats until a `break`. `break` can carry a value, which makes `loop` and labelled blocks
expressions. A label is `:name` before a loop or a block; `break :name` and `continue :name` use it.

```volt
use std::io;

fn main() -> void {
    var x = 1;
    val first = loop {
        if (x * x > 50) {
            break x;
        }
        x++;
    };
    val sign = :pick {
        if (first < 0) {
            break :pick "negative";
        }
        break :pick "positive";
    };
    :rows for (r) in 0..3 {
        for (c) in 0..3 {
            if (c > r) {
                continue :rows;
            }
            std::print("{}{} ", r, c);
        }
    }
    std::println("| {} {}", first, sign);
}
// expect: 00 10 11 20 21 22 | 8 positive
```

A `for` can also build a value: after the iterable, `[ var name: T = start ]` declares an
accumulator, and the loop's value is what it holds at the end.

```volt
use std::io;

fn main() -> void {
    val sum = for (v) in 1..=10 [ var acc: i32 = 0 ] {
        acc += v;
    };
    std::println("{}", sum);
}
// expect: 55
```

## Arrays, slices and ranges

An array's length is part of its type. Slicing an array (`a[1..3]`, or `a[..]` for all of it) gives a
`T[..]` that points into it without copying. Indexing is bounds-checked in debug builds.

```volt
use std::io;

fn sum(xs: i32[..]) -> i32 {
    var total = 0;
    for (x) in xs {
        total += x;
    }
    return total;
}

fn main() -> void {
    val primes: i32[] = { 2, 3, 5, 7, 11 };
    val middle = primes[1..4];
    val evens: i32[] = 0..5;                  // a range fills an array: 0 1 2 3 4
    std::println("{} {} {} {}", primes.len, sum(primes[..]), sum(middle), evens[4]);
}
// expect: 5 28 15 4
```

`{}` is an array of zeros (what a `var` without an initializer holds), and `{x; n}` is `n` copies of
`x`, which runs once; `n` is a constant, the array's length. Both work wherever an array is
expected, struct field defaults and compile time included:

```volt
use std::io;

struct frame {
    data: u8[16] = {};
    tag: u8[2] = { 0xFF; 2 };
}

fn main() -> void {
    val f: frame = {};
    val ones: i32[] = { 1; 4 };
    std::println("{} {} {}", f.data[15], f.tag[1], ones.len);
}
// expect: 0 255 4
```

## Tuples

Tuples group values without declaring a struct. Destructure them with `val (a, b) = ...`, or reach
into them with `.0`, `.1`. Their elements can have names.

```volt
use std::io;

fn min_max(xs: i32[..]) -> (i32, i32) {
    var lo = xs[0];
    var hi = xs[0];
    for (x) in xs {
        if (x < lo) { lo = x; }
        if (x > hi) { hi = x; }
    }
    return (lo, hi);
}

fn main() -> void {
    val data: i32[] = { 4, -2, 9 };
    val (lo, hi) = min_max(data[..]);
    val point: (x: i32, y: i32) = (3, 4);
    std::println("{} {} {} {}", lo, hi, point.x, point.1);
}
// expect: -2 9 3 4
```
