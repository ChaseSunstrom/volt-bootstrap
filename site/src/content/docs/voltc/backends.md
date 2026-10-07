---
title: Backends
description: The C backend, the LLVM backend, and how they agree.
sidebar:
  order: 3
---

The checker turns each function into a small typed IR, and a backend turns the IR into code.
voltc has two, and they're interchangeable: layouts and calling conventions match, so a library
built by one links into a program built by the other.

## C

The C backend writes C that a person can read: named after the Volt it comes from, with a comment
per function saying where it was declared. `voltc emit-c app.volt -o out/` writes it as files:

| File | What's in it |
| --- | --- |
| `volt.h` | the prelude, and every type and function declaration |
| `NAME.c` | one per Volt source file: its functions |
| `glue.c` | generated helpers (deletes, copies, trait dispatch) |
| `runtime.c` | the small runtime: the allocator wrapper and argv |
| `program.c` | includes them all, so `cc out/program.c` builds the program |

Only functions the program can reach are emitted. Here is a function and what it becomes:

```volt
struct point { x: i32; y: i32; }

fn add(a: point, b: point) -> point {
    return { x: a.x + b.x, y: a.y + b.y };
}
```

```c
// add (point.volt:3)
static v_point v_add(v_point a, v_point b) {
    int32_t _s1;
    int32_t _s2;

    _s1 = volt_add_i32(a.x, b.x, "point.volt:4:17");
    _s2 = volt_add_i32(a.y, b.y, "point.volt:4:31");
    return (v_point){ .x = _s1, .y = _s2 };
}
```

`volt_add_i32` is the overflow check (a plain `+` in `--release` builds). The C compiler is
`$CC` (`cc` by default), with `-O2` for release builds.

## LLVM

The LLVM backend generates native code through LLVM's C API, with no C compiler in between (`cc`
still links the program and compiles the tiny C runtime). `voltc emit-llvm` prints the IR.

It's the default on x86-64 and aarch64 (Linux, macOS, FreeBSD). It lowers Windows x64's calling
convention too, but C stays the default there until voltc itself runs on Windows; `--backend c` or
`--backend llvm` chooses either way. A program the LLVM backend can't lower (a C
struct from a header that only the C compiler can lay out) is built through C instead, unless
`--backend llvm` asked for LLVM. C's `static inline` functions from headers are reached through
pointers that a small generated C unit exports.

Debug builds carry DWARF debug information: a breakpoint goes on a Volt line (`break main.volt:12`),
stepping goes statement by statement, and a debugger shows parameters and locals by their Volt
names, with structs, `str`, arrays and pointers laid out as Volt lays them out.

## How they're kept in step

- The golden test suite runs every program through both backends.
- The compiler builds itself through each: the bootstrap check requires the LLVM-built compiler to
  produce the same C and the same LLVM IR as the C-built one.
- Libraries built by one backend are linked into programs built by the other, in both directions.

See [Internals](/volt-bootstrap/internals/backends/) for how the backends work.
