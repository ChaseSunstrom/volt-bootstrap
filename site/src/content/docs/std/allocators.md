---
title: Allocators
description: Where std's memory comes from. Every type that owns memory takes an allocator, as does every function that returns such a value. Includes a fixed buffer, an arena and a failing allocator.
sidebar:
  order: 6
---

std never allocates behind your back. Like in Zig, the memory std uses comes from an allocator you
can choose:

- every type that owns memory takes an allocator type parameter: `string`, `vec`, `map`, `set`,
  `deque`, `heap`, `sorted_map`, `box`, `thread::shared` and `thread::channel`;
- every function that returns such a value takes an allocator argument: `text`'s `split`,
  `replace` and `join`, `path::join`, `fs::read_file` and `list_dir`, `json::parse`,
  `time::utc_iso8601`, `process::cwd`, `string::from`, and the rest.

Both default to `std::mem::default_allocator` (C's `malloc` underneath, and it takes no space), so
`std::string` and `"a,b".split(",")` work as they always have.

## Picking one

A container stores its allocator. Give it one with `new_in(allocator)`, or with an `allocator:`
field in a literal for `vec`, `map` and `deque`. A function puts what it returns in the allocator
you pass.

```volt
use std::io;
use std::text;

fn main() -> !void {
    var arena: std::mem::arena = {};
    val a = arena.allocator();

    var names = std::set<str>::new_in(a);
    names.add("volt");
    var counts: std::map<str, i32, std::mem::arena_allocator> = { allocator: a };
    counts.put("volt", 1);
    val parts = "x,y,z".split(",", a);
    val shout = "loud".to_upper(a);
    std::println("{} {} {} {}", names.len(), counts.len, parts.len, shout.as_str());
} // the arena goes, and everything allocated from it goes with it
// expect: 1 1 3 LOUD
```

## The allocators in std::mem

| Allocator | What it does |
| --- | --- |
| `default_allocator` | C's `malloc`, `realloc` and `free`; in a `--release` build, blocks of up to 256 bytes come from per-thread free lists instead (below) |
| `arena` | takes memory in chunks from a backing allocator; frees do nothing (except for the last block), and deleting or `reset()`ting the arena gives every chunk back |
| `fixed_buffer` | hands out a buffer you own (an array on the stack, a global), front to back, with no heap at all; out of room is `OUT_OF_MEMORY` |
| `failing` | lets the next `left` allocations through, then fails every one: for testing what happens when memory runs out |

In a `--release` build the default allocator keeps a free list per thread for each 16-byte size
class up to 256 bytes, cut from 64 KiB chunks. A small `box` or a short `vec` costs a load and a
store instead of a trip through `malloc`, and needs no lock. A debug build instead stores each
block's size in front of it and checks every `free` and `realloc` against it, since a free with the
wrong size would corrupt a release build's lists. Freed small blocks stay on their thread's lists:
the memory goes back to the program, not to the system.

`arena`, `fixed_buffer` and `failing` hold state. You use them through the handle that
`allocator()` returns, so every container shares that one state. They have to outlive everything
allocated from them. They also aren't safe to use from several threads at once. A `channel` or
`shared<T>` that threads share needs a thread-safe allocator, such as the default one.

```volt
use std::io;

fn main() -> !void {
    var storage: u64[16]; // 128 bytes, aligned for anything up to 8
    var fb: std::mem::fixed_buffer = { buf: @slice(@cast<u8*>(&storage), 128) };
    var v = std::vec<i32>::new_in(fb.allocator());
    var pushed = 0;
    for (k) in 0..100 {
        v.push(k) catch |e| {
            std::println("full after {}: {}", pushed, e);
            break;
        };
        pushed += 1;
    }
}
// expect: full after 32: OUT_OF_MEMORY
```

## When memory runs out

`vec.push`, `vec.reserve`, `box`'s `T::new` and `thread::spawn` and `share` return an error union,
so out of memory is a value you handle. Other operations, such as `string.append`, `map.put` and
`deque.push_back`, panic with "out of memory". Each container also has a `reserve(n)` that returns
`mem_error`. When you're using a bounded allocator, reserve first and those operations won't need to
allocate.

```volt
use std::io;

fn main() -> !void {
    var fail: std::mem::failing = { left: 1 };
    var s = std::string::new_in(fail.allocator());
    try s.reserve(16); // the one allocation allowed
    s.append("fits in 16");
    val more = s.reserve(64);
    more catch |e| {
        std::println("{}: {}", s.as_str(), e);
        return;
    };
}
// expect: fits in 16: OUT_OF_MEMORY
```

## Writing one

An allocator is any type that attaches `std::mem::allocator`. When a block is resized or freed,
the caller passes its size, as in Zig, so an allocator doesn't have to remember sizes:

```volt ignore
trait allocator {
    <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*);
    <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> mem_error!(T*);
    <T: type> fn free(this, ptr: T*, count: usize = 1) -> void;
}
```

A container stores its allocator by value. An allocator with state should therefore be a small
handle that points at that state, as the `allocator()` handles in `std::mem` are.
