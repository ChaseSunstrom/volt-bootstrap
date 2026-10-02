---
title: Builtins
description: Every @builtin function, what it does and where it's allowed.
sidebar:
  order: 15
---

Builtins start with `@`. They're part of the language, not a library.

| Builtin | Gives | |
| --- | --- | --- |
| `@cast<T>(x)` | `T` | converts anything to anything, unchecked. Prefer `x as T`, which only allows safe conversions |
| `@sizeof(T)` | `usize` | a type's size in bytes |
| `@alignof(T)` | `usize` | a type's alignment |
| `@offsetof(T, field)` | `usize` | a field's offset in its struct |
| `@typeof(expr)` | `type` | an expression's type (comptime) |
| `@typeinfo(T)` | typeinfo | a type's description (comptime): names, size, kind, fields... |
| `@typeid(T)`, `@typeid(x)` | `u64` | a type's id, the same in every build; for a trait value, the id of the type it holds. See [Comptime](/volt-bootstrap/guide/comptime/#type-ids-typeid) |
| `@panic("msg")` | `never` | stops the program with a message (exit code 101) |
| `@compile_error("msg")` | `never` | fails compilation where it's reached |
| `@cfg("key")`, `@cfg("key", "value")` | `bool` | a `--cfg` setting, the target's `os`, `arch` or `pointer_bits`, or `"release"` for a `--release` build (comptime) |
| `@slice(ptr, len)` | `T[..]` | a slice over `len` values starting at `ptr`, unchecked |
| `@write(ptr, value)` | `void` | store into memory without deleting what was there |
| `@read(ptr)` | `T` | move a value out of memory without copying or deleting it |
| `@cpp<R>("expr", args...)` | `R` | call C++ code (in a file that imports C++ headers); see [C++](/volt-bootstrap/interop/cpp/) |
| `@attributes([...])` | | attributes on the next declaration; see [Comptime](/volt-bootstrap/guide/comptime/#attributes) |

```volt
use std::io;

extern struct header {
    tag: u8;
    size: u32;
}

fn main() -> void {
    val raw: u8[] = { 1, 2, 3, 4 };
    val view = @slice(&raw[1], 2);
    std::println("{} {} {} {}", @sizeof(header), @offsetof(header, size), view, @cast<i8>(255));
}
// expect: 8 4 { 2, 3 } -1
```

`@read` and `@write` are for containers that manage raw memory, like std's `vec`: they move values
in and out of memory that isn't a variable, without running `delete` on garbage.
