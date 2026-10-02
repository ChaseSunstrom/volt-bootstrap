---
title: How the backends work
description: cgen and lgen, and what keeps their output compatible.
sidebar:
  order: 3
---

## cgen: C

`cgen.volt` writes the IR as C11. Types come first (every struct, union, tagged enum and slice
type, in dependency order), then declarations, then the functions. Names are readable: a Volt
function `geo::area` becomes `v_geo_area`, locals keep their names (renamed only when they'd clash
with a C keyword, a macro from the C library, or another name), and each function starts with a
comment naming its Volt declaration.

Checked arithmetic becomes calls to the prelude's `volt_add_i32` and friends, which use the C
compiler's overflow builtins; release builds use plain wrapping arithmetic.

`emit-c -o DIR` splits the output into `volt.h`, one `.c` per source file, `glue.c` and
`runtime.c`, with a `program.c` that includes them.

## lgen: LLVM

`lgen.volt` builds an LLVM module through the llvm-c API. Layouts are computed to match C's
exactly, and every function uses the C calling convention, including the System V rules for
passing and returning structs in registers or memory. A small C unit is still compiled for the
runtime and for C headers' `static inline` functions, which the LLVM code reaches through pointers.

A few rules keep the LLVM output correct:

- aggregates are copied as plain memory (a tagged union's storage is an integer-and-bytes type,
  never one member's struct, or another member's bytes would be lost);
- zero-filling a large aggregate uses `memset`;
- struct layouts from C headers that Volt can only partly read come from libclang, as the C
  backend's do.

## The runtime, moving into Volt

Every hosted program is compiled with a small runtime: today the C prelude and runtime in
`runtime/`. It is moving into Volt one function at a time. On [bare metal](/volt-bootstrap/voltc/bare-metal/)
(`--target`) there's no C at all already: `std/bare.volt` has the runtime functions the compiler's
code calls (panics, bounds, printing, the heap) and the ones LLVM calls (`memcpy`, 64-bit division
on 32-bit cores), and voltc's start code (`voltc/src/target.volt`) replaces C's `crt0`. A function in std marked `@runtime("volt_print_f64")` is std's Volt version of that runtime
function: both compilers call it wherever they'd call the C one, and both backends can inline it.
The C version stays for programs built without std (`--no-std`).

Printing text goes to the runtime as bytes and a length (`volt_put`), with no `printf` format, and
C strings and error names print through std's `volt_print_cstr`. Format specs are in Volt too:
padding counts UTF-8 characters, integers of any base and width (`i128` included) are divided in
32-bit pieces, so 32-bit cores need no 128-bit division, and a float with a precision (`{:.3}`,
`{:.5e}`) is written from its exact decimal expansion, a big integer for the whole part and one
digit per multiplication by 10 for the fraction, rounded half to even as `printf` does. A test
checks it against `snprintf` on random values. Printing numbers is in Volt
(`std/fmt.volt`): integers by a digit loop, and floats by
Ryu (Ulf Adams, PLDI 2018), the shortest text that reads back as the same value, found by exact
integer arithmetic on the bits. Ryu replaced up to 17 rounds of `snprintf` and `strtod` per float
(the `print` benchmark measures it). Its tables are generated with exact big-integer
arithmetic.

## Compatibility

Both backends produce the same symbols, layouts, error codes and calling conventions, so objects
from one link with the other: the bootstrap check builds libraries with each backend and links them
into programs built by the other.
