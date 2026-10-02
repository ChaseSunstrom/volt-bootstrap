---
title: Closures and function values
description: Closure literals and captures, fn types, and C function pointers.
sidebar:
  order: 10
---

## Closures

A closure is `|captures| (params) -> ret { body }`. The captures list what it takes from the
surrounding scope, and how:

| Capture | Meaning |
| --- | --- |
| `\|x\|` | a copy of `x`, made when the closure is created |
| `\|x&\|` | a reference to `x`: the closure sees and changes the variable |
| `\|move x\|` | takes ownership of `x` |

Parameter types and the return type can be left out when they're clear from the context.

```volt
use std::io;

fn main() -> void {
    var hits = 0;
    val count = |hits&| () {
        hits += 1;
    };
    count();
    count();

    val offset = 10;
    val shift = |offset| (a: i32) -> i32 { return a + offset; };
    std::println("{} {}", hits, shift(5));
}
// expect: 2 15
```

Each closure literal has a type of its own, so a template that takes one (`<F: type> fn
apply(f: F)`) gets a copy with a direct, inlinable call.

### Generic closures

A closure can take type parameters, written before its parameters:
`|captures| <T: type>(x: T) -> T { ... }`. Its captures are taken once, where it's written; each
call works out `T` from the arguments and gets a body for that `T`, like a [generic
function](/volt-bootstrap/guide/templates/#generic-functions). Bounds work too (`<T: show>`).

```volt
use std::io;

fn main() -> void {
    val prefix = ">";
    val show = |prefix| <T: type>(x: T) -> T {
        std::println("{} {}", prefix, x);
        return x;
    };
    show(5);
    show("five");
    val f: fn(f64) -> f64 = show; // a fn value: the body for T = f64
    std::println("{}", f(2.5) * 2.0);
}
// expect: > 5
// expect: > five
// expect: > 2.5
// expect: 5
```

Each call has to tell what `T` is from its arguments: a closure whose parameters don't mention `T`
can't be called.

## Function types

`fn(A, B) -> R` is the type of any function or closure with that signature: a function pointer plus
its captures. Use it to store different functions in one place. Parentheses group a type, so an
array of them is `(fn(i32) -> i32)[]`.

```volt
use std::io;

fn double(n: i32) -> i32 { return n * 2; }

fn apply_all(fs: (fn(i32) -> i32)[..], v: i32) -> void {
    for (f) in fs {
        std::print("{} ", f(v));
    }
    std::println("");
}

fn main() -> void {
    val bonus = 100;
    val fs: (fn(i32) -> i32)[] = {
        double,
        |bonus| (n: i32) -> i32 { return n + bonus; },
        || (n) { return n * n; },
    };
    apply_all(fs[..], 7);
}
// expect: 14 107 49
```

## Owning captures

A closure that captures with `move` owns what it captured, which is deleted with the closure.

```volt
use std::io;

struct job { id: i32; }

attach fn delete(this: job&) -> void {
    std::println("job {} dropped", this.id);
}

fn main() -> void {
    val j: job = { id: 7 };
    val run = |move j| () -> i32 { return j.id; };
    std::println("ran {}", run());
    std::println("end of main");
}
// expect: ran 7
// expect: end of main
// expect: job 7 dropped
```

## C function pointers

`extern "C" fn(A) -> R` is a plain C function pointer, with no captures, for C callbacks. A Volt
function converts to one when it's passed where one is expected:

```volt
use std::io;

extern "C" fn qsort(base: void*, n: usize, size: usize, cmp: extern "C" fn(void*, void*) -> i32) -> void;

fn by_value(a: void*, b: void*) -> i32 {
    return *@cast<i32&>(a) - *@cast<i32&>(b);
}

fn main() -> void {
    var xs: i32[] = { 5, 3, 9, 1 };
    qsort(@cast<void*>(&xs), 4, 4, by_value);
    std::println(xs);
}
// expect: { 1, 3, 5, 9 }
```

A generic function is a value once its generic arguments are given: `name<Args>` is that instance,
as a `fn` value or as a C function pointer.

```volt
use std::io;

extern "C" fn qsort(base: void*, n: usize, size: usize, cmp: extern "C" fn(void*, void*) -> i32) -> void;

<T: type>
fn ascending(a: void*, b: void*) -> i32 {
    return @cast<T&>(a).cmp(@cast<T&>(b));
}

fn main() -> void {
    var xs: f64[] = { 2.5, -1.0, 0.5 };
    qsort(@cast<void*>(&xs), 3, 8, ascending<f64>);
    std::println(xs);
}
// expect: { -1, 0.5, 2.5 }
```
