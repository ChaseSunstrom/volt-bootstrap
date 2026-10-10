---
title: Builtins
description: Every @builtin function, what it does and where it's allowed.
sidebar:
  order: 16
---

Builtins start with `@`. They're part of the language, not a library.

| Builtin | Gives | |
| --- | --- | --- |
| `@cast<T>(x)` | `T` | converts anything to anything, unchecked. Prefer `x as T`, which only allows safe conversions |
| `@bitcast<T>(x)` | `T` | the same bits read as type `T`, which must be the same size; plain data only (no destructor). `@bitcast<u64>(1.0)` is `0x3FF0000000000000`, and `@bitcast<f64>` turns it back. A struct's padding bytes come through undefined |
| `@sizeof(T)` | `usize` | a type's size in bytes |
| `@alignof(T)` | `usize` | a type's alignment |
| `@offsetof(T, field)` | `usize` | a field's offset in its struct |
| `@typeof(expr)` | `type` | an expression's type (comptime) |
| `@typeinfo(T)` | typeinfo | a type's description (comptime): names, size, kind, fields... |
| `@typeid(T)`, `@typeid(x)` | `u64` | a type's id, the same in every build; for a trait value, the id of the type it holds. See [Comptime](/volt-bootstrap/guide/comptime/#type-ids-typeid) |
| `@expand(expr)` | `expr`'s | `expr`, noting at compile time what it became: a comptime value, or the generic instance a call runs. See [Comptime](/volt-bootstrap/guide/comptime/#what-comptime-code-became-expand-and-voltc-expand) |
| `@embed("path")` | `str` | a file's bytes, read at compile time; the path is relative to the source file. See [Reading files](/volt-bootstrap/guide/comptime/#reading-files-embed) |
| `@vector(T, n)` | `type` | the SIMD vector of `n` numbers of type `T` (comptime); `std::simd` names them. See [SIMD vectors](/volt-bootstrap/std/math-functions/#simd-vectors) |
| `@discriminant(v)` | `i64` | which variant an enum value (or a reference to one) holds: its discriminant, as `@typeinfo` lists it |
| `@field(v, "name")` | the field | `v.name`, the name a comptime string (or a tuple element's index, a comptime integer): read, assigned, borrowed; called, `@field(v, "name")(args)` is the method `v.name(args)` (and `@field(T, "name")(args)` is `T::name(args)`). See [Comptime](/volt-bootstrap/guide/comptime/#reflection-typeinfo-and-typeof) |
| `@has_field(T, "name")` | `bool` | is `T` a struct with that field (comptime) |
| `@has_method(T, "name", A...)` | `bool` | does `T` have a method of that name, taking `A...` first (comptime). See [Comptime](/volt-bootstrap/guide/comptime/#does-a-type-attach-a-trait-attaches) |
| `@attaches(T, some_trait)` | `bool` | does `T` attach the trait, as a `<T: some_trait>` bound asks (comptime). See [Comptime](/volt-bootstrap/guide/comptime/#does-a-type-attach-a-trait-attaches) |
| `@panic("msg")` | `never` | stops the program with a message (exit code 101) |
| `@compile_error("msg")` | `never` | fails compilation where it's reached |
| `@cfg("key")`, `@cfg("key", "value")` | `bool` | a `--cfg` setting, the target's `os`, `arch` or `pointer_bits`, `target` (the `--target` name, on bare metal), `"hosted"` (an OS at all), `"unix"` (Linux, macOS or FreeBSD), or `"release"` for a `--release` build (comptime) |
| `@slice(ptr, len)` | `T[..]` | a slice over `len` values starting at `ptr`, unchecked |
| `@write(ptr, value)` | `void` | store into memory without deleting what was there |
| `@read(ptr)` | `T` | move a value out of memory without copying or deleting it |
| `@volatile_read(ptr)`, `@volatile_write(ptr, value)` | `T`, `void` | a load or store the compiler keeps, in order, exactly as written: memory-mapped hardware registers. Plain values only (ints, floats, pointers) |
| `@cpp<R>("expr", args...)`, `@cpp("expr", args...)` | `R` | call C++ code (in a file that imports C++ headers); without `<R>`, clang works out the result type. See [C++](/volt-bootstrap/interop/cpp/#calls-worked-out-per-use) |
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

## Attributes

Attributes go in `@attributes([...])` before a declaration (see
[Comptime](/volt-bootstrap/guide/comptime/#attributes)). The editor lists them, and the builtins
above, after `@`, with what each does.

| Attribute | On | What it does |
| --- | --- | --- |
| `@inline`, `@noinline` | a fn | always, or never, inline it |
| `@opt(level)` | a fn | its optimization level |
| `@unchecked` | a fn | no bounds checks in its body, for code that proves its own indices |
| `@invalidates` | a method | it may move or free its receiver's storage: borrows into it end at the call |
| `@section("name")` | a fn, a global | put it in a linker section |
| `@align(n)` | a global, a struct | its alignment, in bytes |
| `@deprecated("why")` | anything | using it warns with this message |
| `@owns("field")` | a struct | it owns what this pointer field points to (for borrow checking) |
| `@thread_local` | a global `var` | each thread has its own copy |
| `@cfg("key", "value")` | any item | the item is only in builds where this holds (as the builtin above) |
| `@derive(trait, ...)` | a struct, an enum | attach these traits (std's derive when they aren't in scope) |
| `@optional` | a trait fn | an attach block may leave it out |
| `@closed` | a trait | its attach blocks hold its fns only: its values are a closed set, and calls on them switches |
| `@attach_as("Struct")` | a trait | the struct attach blocks name for it (a C++ class's virtuals) |
| `@export_text("method")` | a struct | it's text to other languages, as the method gives it (`voltc bindings`) |
| `@instance(T, ...)` | a generic export fn | export this instance, a type per generic parameter (`sum_i32`; `voltc bindings`) |
| `@rust_generic("mod::f")` | a generic fn or struct `use rust`, `use zig` or `use go` declares | built per instance a program uses (bolt writes it) |
| `@standard("c++17")` | a `use { "x.h" }` | the C or C++ standard its headers are read and compiled under (`c89` ... `c23`, `c++98` ... `c++26`, GNU's `gnu11`, `gnu++20` too); the newest the compilers take when left out |
| `@cpp_type("ns::Class")`, `@cpp_handle("ns::Class")`, `@cpp_call("ns::f")` | a struct, a fn | what `use cpp` writes: the struct is that C++ class (laid out by Volt, or held by handle: then a method it doesn't have is worked out by clang per use); the fn is called per use |
| `@intrinsic("name")`, `@runtime("symbol")` | a fn | std's and libraries' own files only: binds a function the compiler provides (`println`), or one the generated code calls |
