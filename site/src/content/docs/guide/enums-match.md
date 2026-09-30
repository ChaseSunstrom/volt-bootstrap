---
title: Enums and match
description: Plain enums, enums with payloads, generic enums, and pattern matching.
sidebar:
  order: 4
---

## Enums

A plain enum is a set of named values. The backing integer type is optional (the smallest one that
fits by default), and a variant can pick its value.

```volt
use std::io;

enum level: u8 {
    DEBUG,          // 0
    INFO,           // 1
    WARN = 10,
    ERROR,          // 11
}

fn main() -> void {
    val l = level::WARN;
    std::println("{} {} {}", l, l as i32, level::ERROR as i32);
}
// expect: WARN 10 11
```

Enums compare with `==` and print their variant's name.

## Payloads

Variants can carry data: one value, a tuple, or a tuple with named elements.

```volt
use std::io;

enum event {
    KEY: u8,
    CLICK: (x: i32, y: i32),
    RESIZE: (i32, i32),
    QUIT,
}

fn main() -> void {
    val events: event[] = { event::KEY('a'), event::CLICK(10, 20), .RESIZE(800, 600), .QUIT };
    for (e) in events {
        std::println(e);
    }
}
// expect: KEY(97)
// expect: CLICK(10, 20)
// expect: RESIZE(800, 600)
// expect: QUIT
```

`.QUIT` is short for `event::QUIT` wherever the type is already known.

Enums can be generic too:

```volt
use std::io;

<T: type>
enum tree {
    LEAF: T,
    EMPTY,
}

fn main() -> void {
    val t: tree<str> = tree<str>::LEAF("x");
    std::println(t);
}
// expect: LEAF(x)
```

## match

`match` compares a value against patterns, top to bottom. It's an expression, and it has to cover
every case: list every variant, or end with `default`.

```volt
use std::io;

enum event {
    KEY: u8,
    CLICK: (x: i32, y: i32),
    QUIT,
}

fn describe(e: event) -> str {
    return match (e) {
        .KEY(k) if k == 'q' => "quit key",       // a guard
        .KEY(k) => "a key",
        .CLICK(x, y) => "a click",
        .QUIT => "quit",
    };
}

fn main() -> void {
    std::println("{} {} {}", describe(event::KEY('q')), describe(event::CLICK(1, 2)), describe(.QUIT));
}
// expect: quit key a click quit
```

Missing a case is a compile error:

```volt fail
enum light { RED, YELLOW, GREEN }

fn next(l: light) -> light {
    return match (l) {
        .RED => light::GREEN,
        .GREEN => light::YELLOW,
    };
}
// error: YELLOW
```

### Other patterns

Integers, ranges, strings, booleans and tuples match too; `_` matches anything, and a name binds
the value (often with a guard).

```volt
use std::io;

fn size(n: i32) -> str {
    return match (n) {
        0 => "none",
        1..=9 => "a few",
        x if x < 0 => "negative",
        default => "lots",
    };
}

fn main() -> void {
    std::println("{} {} {} {}", size(0), size(4), size(-2), size(99));
    val pair = (2, true);
    match (pair) {
        (0, _) => std::println("zero"),
        (n, true) => std::println("{} and true", n),
        default => std::println("other"),
    }
}
// expect: none a few negative lots
// expect: 2 and true
```

### Binding by reference

A binding copies the payload. `.V(x&)` binds a reference to the payload in place instead, to read
a large value without copying it, or to change it.

```volt
use std::io;

enum slot {
    FULL: i32,
    FREE,
}

fn main() -> void {
    var s = slot::FULL(1);
    match (s) {
        .FULL(n&) => { *n += 10; },
        .FREE => {},
    }
    std::println(s);
}
// expect: FULL(11)
```

Error sets and [trait unions](/volt-bootstrap/guide/traits/) are matched the same way.
