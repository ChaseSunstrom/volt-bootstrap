---
title: Async
description: Stackless frames driven by hand with async, suspend, resume and await.
sidebar:
  order: 12
---

An `async fn` can pause itself with `suspend` and be continued later. Its state lives in a
**frame**: a plain value whose size is known at compile time, stored wherever you put it (a local,
a field). There is no heap allocation, no scheduler and no runtime: you drive frames yourself, and
an event loop can be a library on top.

| | |
| --- | --- |
| `val f = async g(args)` | start `g`; it runs until its first `suspend` (or the end) |
| `suspend` | inside an async fn: pause here |
| `resume f` | run `f` until its next `suspend` |
| `await f` | run `f` to the end and give its result |
| `await g(args)` | call and wait in one step |

A plain call of an async fn (without `async`) just runs it to the end.

```volt
use std::io;

async fn phases() -> i32 {
    var result = 10;
    suspend;
    result += 5;
    suspend;
    return result * 2;
}

fn main() -> void {
    val f = async phases();       // runs to the first suspend
    resume f;                     // to the second
    std::println("{}", await f);  // to the end
    std::println("{}", phases()); // a plain call: to the end, right away
}
// expect: 30
// expect: 30
```

## Generators

Parameters, locals and loop state all live in the frame across suspends, so a generator is just a
loop with a `suspend` in it:

```volt
use std::io;

async fn count(from: i32, to: i32, out: i32&) -> void {
    for (i) in from..to {
        *out = i;
        suspend;
    }
}

fn main() -> void {
    var cur = 0;
    val g = async count(3, 6, &cur);
    std::print("{} ", cur);
    resume g;
    std::print("{} ", cur);
    resume g;
    std::println("{}", cur);
    await g;
}
// expect: 3 4 5
```

## Cleanup

A frame owns its locals. A frame deleted before it finishes runs its `defer`s and deletes what it
holds, like a scope that ends early.

```volt
use std::io;

async fn task(label: str) -> void {
    defer std::println("{} cleaned up", label);
    std::println("{} started", label);
    suspend;
    std::println("{} finished", label);
}

fn main() -> void {
    {
        val t = async task("a");
    }                              // never resumed: its defer runs here
    std::println("end");
}
// expect: a started
// expect: a cleaned up
// expect: end
```

`main` can't be async, and a frame can't be copied (it may point into itself).
