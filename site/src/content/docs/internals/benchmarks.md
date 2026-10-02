---
title: Benchmarks
description: Volt against C and C++ on the same programs, and how to run the comparison.
sidebar:
  order: 6
---

`bench/` has the same programs written in C, C++ and Volt, each in the way that language's
programmers would usually write it. Every program prints the same output in each language:

| Program | What it measures |
| --- | --- |
| `nbody` | floating-point arithmetic over an array of structs (the Benchmarks Game) |
| `spectral_norm` | nested loops of float math over vectors |
| `fannkuch` | integer work and array indexing over every permutation |
| `binary_trees` | allocating and freeing many small objects (`box` against `malloc` and `unique_ptr`) |
| `mandelbrot` | a tight float loop with an early exit |
| `hashmap` | `std::map` against a hand-written C hash table and `std::unordered_map` |
| `strings` | building and splitting text (`std::string` against a C buffer and `std::string`) |
| `sort` | `slice.sort` (stable) against `qsort` and `std::stable_sort` |
| `closures` | closures passed to a template, against C function pointers and C++ lambdas |
| `matmul` | a dense matrix multiply over growable arrays (`std::vec` against `malloc` and `std::vector`) |
| `sieve` | the sieve of Eratosthenes over a 200 MB byte array |
| `fib` | naive recursive Fibonacci: nothing but function calls |
| `vec_grow` | pushing 20 million values without reserving, ten times (`std::vec` against `realloc` and `std::vector`) |
| `crc32` | table-driven CRC-32 over 256 MiB, a byte at a time |
| `print` | a million lines: shortest round-trip floats (`println` against libc's `%.*g` + `strtod` tries and C++'s `std::to_chars`), then integers |

## Running it

```sh
cargo test --release --test bench -- --ignored --nocapture
```

The harness builds each program five ways. C is built with clang `-O2` and with gcc `-O2`, and C++
with clang++ `-O2`. Volt is built with `--release` through both of voltc's backends: C, compiled by
clang, and LLVM. Each build runs best of three, and every build has to print the same output.
`BENCH_ONLY=nbody,sort` runs only some of the programs, and `BENCH_RUNS=5` takes the best of five.
`BENCH_MAX_RATIO=1.25` fails when a Volt build takes more than 1.25 times as long as C (clang). A
full run rewrites the table below.

To see where one of them spends its time, run it under [`bolt hot`](/volt-bootstrap/bolt/commands/#finding-the-hot-spots):
`bolt hot bench/binary_trees/main.volt -- 18`.

## Results

A full run writes what follows: the machine and toolchain it ran on, then the times. Each time is
the best of the runs, and each one after C (clang) also shows its ratio to it (below 1.00x is
faster). Times move a few percent between runs; differences that small are noise.

<!-- bench:start -->
Measured 2026-10-02 on:

- **CPU**: AMD Ryzen 7 9800X3D 8-Core Processor (8 cores, 16 threads, `powersave` frequency governor)
- **Memory**: 60 GiB
- **OS**: Arch Linux, kernel 7.2.7-hardened1-1-hardened
- **C and C++**: clang version 22.1.8; gcc (GCC) 16.2.1 20260810
- **Volt**: voltc --release; its LLVM backend on LLVM 22.1.8
- **Timing**: best of 5 runs, wall clock

| Program | C (clang) | C (gcc) | C++ (clang++) | Volt (C backend) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: |
| binary_trees | 0.703 s | 0.656 s (0.93x) | 0.945 s (1.34x) | 0.361 s (0.51x) | 0.283 s (0.40x) |
| closures | 0.475 s | 0.736 s (1.55x) | 0.529 s (1.11x) | 0.567 s (1.19x) | 0.478 s (1.01x) |
| crc32 | 0.694 s | 0.693 s (1.00x) | 0.693 s (1.00x) | 0.698 s (1.01x) | 0.690 s (0.99x) |
| fannkuch | 1.894 s | 1.910 s (1.01x) | 1.925 s (1.02x) | 1.961 s (1.04x) | 1.906 s (1.01x) |
| fib | 0.453 s | 0.178 s (0.39x) | 0.449 s (0.99x) | 0.440 s (0.97x) | 0.438 s (0.97x) |
| hashmap | 0.545 s | 0.552 s (1.01x) | 1.275 s (2.34x) | 0.545 s (1.00x) | 0.533 s (0.98x) |
| mandelbrot | 0.636 s | 0.615 s (0.97x) | 0.638 s (1.00x) | 0.637 s (1.00x) | 0.639 s (1.01x) |
| matmul | 0.508 s | 0.469 s (0.92x) | 0.506 s (1.00x) | 0.502 s (0.99x) | 0.508 s (1.00x) |
| nbody | 0.721 s | 0.715 s (0.99x) | 0.680 s (0.94x) | 0.712 s (0.99x) | 0.725 s (1.01x) |
| print | 1.001 s | 1.010 s (1.01x) | 0.049 s (0.05x) | 0.066 s (0.07x) | 0.069 s (0.07x) |
| sieve | 0.531 s | 0.570 s (1.07x) | 0.532 s (1.00x) | 0.530 s (1.00x) | 0.510 s (0.96x) |
| sort | 0.568 s | 0.562 s (0.99x) | 0.190 s (0.33x) | 0.228 s (0.40x) | 0.226 s (0.40x) |
| spectral_norm | 0.959 s | 0.646 s (0.67x) | 0.936 s (0.98x) | 0.937 s (0.98x) | 0.938 s (0.98x) |
| strings | 0.281 s | 0.282 s (1.00x) | 0.380 s (1.35x) | 0.252 s (0.90x) | 0.267 s (0.95x) |
| vec_grow | 0.543 s | 0.544 s (1.00x) | 1.253 s (2.31x) | 0.525 s (0.97x) | 0.523 s (0.96x) |
<!-- bench:end -->

## Reading the results

- **Most rows are a tie.** Volt compiles to the same machine code as C for the same loops: the C
  backend hands clang C that does what the C program does, and the LLVM backend emits the same IR
  clang would.
- **`sort`: templates beat function pointers.** `slice.sort` and `std::stable_sort` are templates,
  so the comparison is inlined; C's `qsort` calls a function through a pointer for every one.
- **`vec_grow`: Volt values move by copying bytes**, so `std::vec` grows with `realloc`, which can
  extend a buffer in place, as the hand-written C does. `std::vector` can't: it allocates a new
  buffer and moves each element across.
- **`hashmap`**: C++'s `std::unordered_map` allocates a node per entry; `std::map` in Volt and the C
  table don't.
- **`sieve`**: `vec.resize(n, 1)` fills with one plain loop, which clang turns into the same
  `memset` the C program calls. (Filling with `push` was 14% slower: each push stores the length
  back, and a byte store may alias it, so the loop can't be turned into a memset.)
- **`binary_trees`: free lists beat `malloc`.** In a `--release` build std's default allocator
  takes small blocks from per-thread free lists ([allocators](/volt-bootstrap/std/allocators/)), so
  a `box` costs a load and a store, and a `box<node>?` is a pointer, so a node is 16 bytes like
  C's. The C and C++ programs call `malloc` and `new` for every node (before the free lists, Volt
  was 1.14x to 1.18x). A C program with its own pool would match it:
  this row measures the allocators, not the compilers. The arena idiom (a `std::mem::arena` per tree,
  `node::new(value, arena.allocator())`, `reset()` after each) measured 0.85x on the C backend and
  0.83x on LLVM: a box from an arena carries the arena's pointer, so each node is twice the size
  or more, and the free lists win.
- **`print`: floats are printed by Ryu, in Volt.** libc has no shortest-round-trip float printing,
  so C tries `%.*g` with more digits until `strtod` reads the value back. C++'s `std::to_chars`
  does what Volt does, and is ahead of it here: each `println` still writes through C's stdio twice
  (the value, then the newline), where C++ makes one `printf` call. Volt's own output buffer is next.
- **gcc's own wins** (`fib`, `spectral_norm`) are its optimizer's: it turns much of `fib`'s
  recursion into loops. Volt's C backend is compiled by clang here, so it follows clang.
