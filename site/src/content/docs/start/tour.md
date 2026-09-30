---
title: A tour of Volt
description: The whole language in one page, each part linked to its chapter.
sidebar:
  order: 3
---

This page walks through Volt quickly. Every example is a whole program you can paste into a file and
`voltc run`; each section links to the chapter with the details. The `// expect:` lines at the end
of an example are what it prints (the site's tests run every example and check). `examples/tour.volt`
in the repository is a longer tour.

## Values and control flow

`val` declares a constant, `var` a variable. Types are inferred from the value, or written after a
colon. Conditions are `bool`; blocks always have braces.

```volt
use std::io;

fn main() -> void {
    val limit: i32 = 5;
    var total = 0;                 // i32
    for (i) in 0..limit {          // 0, 1, 2, 3, 4
        if (i % 2 == 0) {
            total += i;
        }
    }
    var kind = "small";
    if (total > 5) {
        kind = "big";
    }
    std::println("{} {}", total, kind);
}
// expect: 6 big
```

More in [Basics](/volt-bootstrap/guide/basics/).

## Functions, structs and methods

Functions can be overloaded. Methods are functions attached to a type, declared outside it with
`attach fn`; `this` is the value they're called on.

```volt
use std::io;

struct point {
    x: f64;
    y: f64 = 0.0;                  // a default: the literal can leave it out
}

attach fn scaled(this: point&, k: f64) -> point {
    return { x: this.x * k, y: this.y * k };
}

fn describe(p: point) -> str { return "a point"; }
fn describe(n: i32) -> str { return "a number"; }

fn main() -> void {
    val p: point = { x: 1.5 };
    val q = p.scaled(2.0);
    std::println("{} {} {} {}", q.x, q.y, describe(q), describe(3));
}
// expect: 3 0 a point a number
```

More in [Functions](/volt-bootstrap/guide/functions/) and [Structs and methods](/volt-bootstrap/guide/structs/).

## Enums and match

Enum variants can carry data. `match` is an expression, and it has to cover every case.

```volt
use std::io;

enum shape {
    CIRCLE: f64,
    RECT: (f64, f64),
    EMPTY,
}

fn area(s: shape) -> f64 {
    return match (s) {
        .CIRCLE(r) => 3.0 * r * r,
        .RECT(w, h) => w * h,
        .EMPTY => 0.0,
    };
}

fn main() -> void {
    std::println("{} {}", area(shape::CIRCLE(1.0)), area(shape::RECT(2.0, 3.0)));
}
// expect: 3 6
```

More in [Enums and match](/volt-bootstrap/guide/enums-match/).

## Errors and optionals

A function that can fail returns `E!T`. `try` passes the error up; `catch` handles it. `T?` is a
value that may be missing; `??` supplies a fallback, and `if (x)` checks and unwraps it.

```volt
use std::io;

error lookup_error { NOT_FOUND }

fn find(key: str) -> lookup_error!i32 {
    if (key == "answer") {
        return 42;
    }
    return lookup_error::NOT_FOUND;
}

fn main() -> void {
    val a = find("answer") catch 0;
    val b = find("question") catch |e| {
        std::println("no luck: {}", e);
        return;
    };
    std::println("{} {}", a, b);
}
// expect: no luck: NOT_FOUND
```

More in [Errors and optionals](/volt-bootstrap/guide/errors/).

## Ownership

A value is deleted when its owner's scope ends. Using a value hands it over (a move); `copy` makes
a second one. `box<T>` owns memory on the heap.

```volt
use std::io;

fn total(v: std::vec<i32>) -> i32 {      // takes ownership: v is deleted when total returns
    var sum = 0;
    for (x) in v.items() {
        sum += x;
    }
    return sum;
}

fn main() -> !void {
    var v: std::vec<i32> = {};
    try v.push(1);
    try v.push(2);
    val w = copy v;                      // a deep copy
    std::println("{}", total(v));        // v moves into total
    std::println("{}", w.len);           // w is still ours
    val b = try i32::new(7);             // box<i32>
    std::println("{}", b);
}
// expect: 3
// expect: 2
// expect: 7
```

More in [Ownership](/volt-bootstrap/guide/ownership/).

## Templates and traits

`<T: type>` makes a template: a copy of the function for each type it's used with. A trait is a
constraint, and used as a type, a tagged union of the types that attach it.

```volt
use std::io;

<T: type>
fn twice(x: T) -> T {
    return x + x;
}

trait t_named {
    fn name(this) -> str;
}

struct cat {}
struct dog {}

attach t_named -> cat {
    fn name(this) -> str { return "cat"; }
}

attach t_named -> dog {
    fn name(this) -> str { return "dog"; }
}

fn main() -> void {
    std::println("{} {}", twice(21), twice(1.25));
    val c: cat = {};
    val d: dog = {};
    val pets: t_named[] = { c, d };
    for (p&) in pets {
        std::print("{} ", p.name());
    }
    std::println("");
}
// expect: 42 2.5
// expect: cat dog
```

More in [Templates](/volt-bootstrap/guide/templates/) and [Traits](/volt-bootstrap/guide/traits/).

## Closures, comptime and async

```volt
use std::io;

comptime fn cube(n: i32) -> i32 {        // runs in the compiler
    return n * n * n;
}

async fn steps() -> i32 {
    var n = 1;
    suspend;                             // pause here
    n += 1;
    return n;
}

fn main() -> void {
    var count = 0;
    val bump = |count&| () {             // captures count by reference
        count += 1;
    };
    bump();
    bump();
    val frame = async steps();           // runs until its first suspend
    resume frame;
    std::println("{} {} {}", count, cube(3), await frame);
}
// expect: 2 27 2
```

More in [Closures](/volt-bootstrap/guide/closures/), [Comptime](/volt-bootstrap/guide/comptime/) and
[Async](/volt-bootstrap/guide/async/).

## C, right there

```volt
use std::io;
use { "stdlib.h" } as c;                 // a real C header

fn main() -> void {
    std::println("{}", c::abs(-5));
}
// expect: 5
```

More in [Interop](/volt-bootstrap/interop/c/).
