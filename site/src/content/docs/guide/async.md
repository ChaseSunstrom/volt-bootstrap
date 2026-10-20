---
title: Async
description: Stackless frames driven by hand with async, suspend, resume and await.
sidebar:
  order: 13
---

An `async fn` can pause itself with `suspend` and be continued later. Its state lives in a
**frame**: a plain value whose size is known at compile time, built in place in the local that
`val f = async g(args)` declares. There is no heap allocation, no scheduler and no runtime: you
drive frames yourself, and an event loop can be a library on top.

| | |
| --- | --- |
| `val f = async g(args)` | start `g`; it runs until its first `suspend` (or the end) |
| `suspend` | inside an async fn: pause here |
| `resume f` | run `f` until its next `suspend` |
| `await f` | run `f` to the end and give its result |
| `await g(args)` | call and wait in one step |

A plain call of an async fn (without `async`) just runs it to the end. Resuming a frame that has
finished, or awaiting one twice, stops the program (`panic: resumed a frame that already
finished`), in release builds too.

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

A `defer` can `suspend` too: the frame pauses there on its way out (a `return`, a `try`'s early
return, a `break`, the end of a block or of the fn). A frame deleted while paused in a defer, or
before it reached one, finishes its defers without pausing.

## Moving frames

A frame can't be copied, but it moves like any owned value: into another variable, or into a
container of them (`@typeof(x)` is `x`'s type, wherever a type goes). It's resumed and awaited
where it went, and deleted where it ends up.

```volt
use std::io;

async fn job(name: str) -> void {
    defer {
        std::println("{} saving", name);
        suspend;                       // pauses on the way out too
        std::println("{} saved", name);
    }
    std::println("{} working", name);
    suspend;
}

fn main() -> void {
    val a = async job("a");
    var queue: std::vec<@typeof(a)> = {};
    queue.push(a);                     // a moves into the queue
    for (f&) in queue.items() {
        resume f;
    }
    for (f&) in queue.items() {
        resume f;
    }
}
// expect: a working
// expect: a saving
// expect: a saved
```

A move copies the frame's bytes. A frame where one local holds a reference to another
(`val p = &n;`, or a slice of a local array) across a `suspend` would still point into the old
frame after a move, so moving it warns (`moving this frame of 'f' leaves it pointing into the old
frame ('p' holds a reference to 'n' across a suspend)`); resume or await such a frame where it is.
A string's or vec's text is in memory of its own, so a view of it moves safely.

`main`, an `export` fn and an `extern` fn with a body can be async: called from outside Volt (the
start code, C, an `extern "C" fn` pointer), they run their frame to the end, as a plain call does.
A bodiless `extern` fn can't be async, since a C function has no frame. `suspend` can't go in a
`match`, loop or block used as a value, or in a defer that a `break` or `continue` from inside an
expression runs (`x ?? break`). An async fn can't start itself with `async` (its frame
would hold itself), but it can call or `await` itself.

A Rust crate's `async fn` comes in as a Volt async fn: see
[Volt calls Rust](/volt-bootstrap/interop/rust-and-zig/#volt-calls-rust).
