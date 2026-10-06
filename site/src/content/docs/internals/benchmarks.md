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
| `sort` | sorting 5 million integers with each standard library's sort: `slice.sort` (stable; for integers a radix sort) against `qsort` and `std::stable_sort` |
| `closures` | closures passed to a template, against C function pointers and C++ lambdas |
| `matmul` | a dense matrix multiply over growable arrays (`std::vec` against `malloc` and `std::vector`) |
| `sieve` | the sieve of Eratosthenes over a 200 MB byte array |
| `fib` | naive recursive Fibonacci: nothing but function calls |
| `vec_grow` | pushing 20 million values without reserving, ten times (`std::vec` against `realloc` and `std::vector`) |
| `crc32` | table-driven CRC-32 over 256 MiB, a byte at a time |
| `print` | a million lines: shortest round-trip floats (`println` against libc's `%.*g` + `strtod` tries and C++'s `std::to_chars`), then integers |
| `raytrace` | vector math through operators (`attach operator` against C functions and C++ overloads): spheres, shadows and mirror bounces |
| `vm_interp` | a bytecode interpreter: an enum with payloads and `match` against a C tagged union with `switch` and C++'s `std::variant` with `std::visit` |
| `shapes` | dynamic dispatch over a million shapes: a trait held inline in a `std::vec` against C function-pointer tables and C++ virtual calls through `unique_ptr` |
| `errors` | parsing where about 1 line in 20 fails: error unions with `try` against C status codes and C++ exceptions |
| `json` | writing a 73 MB JSON document, parsing it into a tree and walking it (`std::json` against hand-written C and C++ parsers) |
| `csv` | formatting and parsing records with floats and quoted fields (`{:.2}` and `parse_float` against `snprintf` and `strtod`, and C++'s `std::format_to` and `from_chars`) |
| `wordfreq` | counting 20 million words and taking the top 20 (`std::map<str, i64>` against a C hash table and `std::unordered_map<std::string, long>`) |
| `lru_cache` | an LRU cache under 20 million skewed operations: a chained hash table over linked nodes (in a `std::vec` with indexes, against C's malloc'd nodes and pointers), and C++'s `std::list` with `std::unordered_map` |
| `heap` | a priority queue of numbers and of structs (`std::heap` against a C `void*` heap with a comparator and `std::priority_queue`) |
| `dijkstra` | shortest paths across a 1500 by 1500 grid with a binary heap |
| `nqueens` | counting N-queens solutions with bitboards and recursion |
| `bigint` | arbitrary precision in base 10^9 limbs: a factorial, a Fibonacci number by additions, and a schoolbook product |
| `sha256` | SHA-256 over 256 MiB: rotates, shifts and 32-bit adds |
| `lz77` | compressing 64 MiB with hash chains, decompressing it and checking the round trip |
| `knucleotide` | counting k-mers of a 25 million base DNA string with rolling 2-bit keys in hash tables (the Benchmarks Game) |
| `lexer` | tokenizing 32 MiB of source text: a `match` on `str` keywords against C `memcmp` tables and C++ `string_view` compares |

## Running it

```sh
cargo test --release --test bench -- --ignored --nocapture
```

The harness builds each program six ways. C is built with clang `-O2` and with gcc `-O2`, and C++
with clang++ `-O2`. Volt is built with `--release` through both of voltc's backends: C, compiled by
clang and by gcc, and LLVM. Each build runs best of three, and every build has to print the same output.
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
Measured 2026-10-06 on:

- **CPU**: AMD Ryzen 7 9800X3D 8-Core Processor (8 cores, 16 threads, `powersave` frequency governor)
- **Memory**: 60 GiB
- **OS**: Arch Linux, kernel 7.2.8-hardened1-2-hardened
- **C and C++**: clang version 23.1.1; gcc (GCC) 16.2.1 20260810
- **Volt**: voltc --release; its LLVM backend on LLVM 23.1.1
- **Timing**: best of 3 runs, wall clock

| Program | C (clang) | C (gcc) | C++ (clang++) | Volt (C, clang) | Volt (C, gcc) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| bigint | 0.537 s | 0.444 s (0.83x) | 0.544 s (1.01x) | 0.546 s (1.02x) | 1.857 s (3.46x) | 0.554 s (1.03x) |
| binary_trees | 0.721 s | 0.654 s (0.91x) | 0.907 s (1.26x) | 0.354 s (0.49x) | 0.364 s (0.50x) | 0.294 s (0.41x) |
| closures | 0.479 s | 0.738 s (1.54x) | 0.540 s (1.13x) | 0.539 s (1.13x) | 0.654 s (1.37x) | 0.483 s (1.01x) |
| crc32 | 0.719 s | 0.710 s (0.99x) | 0.707 s (0.98x) | 0.700 s (0.97x) | 0.761 s (1.06x) | 0.706 s (0.98x) |
| csv | 0.656 s | 0.648 s (0.99x) | 0.580 s (0.88x) | 0.304 s (0.46x) | 0.394 s (0.60x) | 0.371 s (0.56x) |
| dijkstra | 0.428 s | 0.517 s (1.21x) | 0.455 s (1.06x) | 0.486 s (1.14x) | 0.503 s (1.17x) | 0.498 s (1.16x) |
| errors | 0.690 s | 0.699 s (1.01x) | 1.310 s (1.90x) | 0.676 s (0.98x) | 0.735 s (1.07x) | 0.726 s (1.05x) |
| fannkuch | 1.867 s | 1.899 s (1.02x) | 1.931 s (1.03x) | 1.996 s (1.07x) | 1.679 s (0.90x) | 1.977 s (1.06x) |
| fib | 0.452 s | 0.174 s (0.38x) | 0.452 s (1.00x) | 0.451 s (1.00x) | 0.164 s (0.36x) | 0.440 s (0.97x) |
| hashmap | 0.560 s | 0.581 s (1.04x) | 1.523 s (2.72x) | 0.498 s (0.89x) | 0.573 s (1.02x) | 0.503 s (0.90x) |
| heap | 0.595 s | 1.345 s (2.26x) | 0.609 s (1.02x) | 0.524 s (0.88x) | 0.620 s (1.04x) | 0.520 s (0.87x) |
| json | 0.640 s | 0.672 s (1.05x) | 0.597 s (0.93x) | 0.475 s (0.74x) | 0.642 s (1.00x) | 0.432 s (0.67x) |
| knucleotide | 0.757 s | 0.914 s (1.21x) | 0.737 s (0.97x) | 0.711 s (0.94x) | 1.053 s (1.39x) | 0.703 s (0.93x) |
| lexer | 0.550 s | 0.649 s (1.18x) | 0.745 s (1.35x) | 0.466 s (0.85x) | 0.562 s (1.02x) | 0.522 s (0.95x) |
| lru_cache | 0.572 s | 0.566 s (0.99x) | 1.309 s (2.29x) | 0.527 s (0.92x) | 0.767 s (1.34x) | 0.536 s (0.94x) |
| lz77 | 0.604 s | 0.588 s (0.97x) | 0.649 s (1.07x) | 0.693 s (1.15x) | 0.783 s (1.29x) | 0.675 s (1.12x) |
| mandelbrot | 0.637 s | 0.616 s (0.97x) | 0.639 s (1.00x) | 0.639 s (1.00x) | 0.619 s (0.97x) | 0.638 s (1.00x) |
| matmul | 0.507 s | 0.481 s (0.95x) | 0.505 s (1.00x) | 0.516 s (1.02x) | 1.016 s (2.00x) | 0.517 s (1.02x) |
| nbody | 0.702 s | 0.715 s (1.02x) | 0.680 s (0.97x) | 0.701 s (1.00x) | 0.772 s (1.10x) | 0.722 s (1.03x) |
| nqueens | 0.832 s | 0.802 s (0.96x) | 0.876 s (1.05x) | 0.849 s (1.02x) | 1.425 s (1.71x) | 0.833 s (1.00x) |
| print | 1.006 s | 1.027 s (1.02x) | 0.049 s (0.05x) | 0.046 s (0.05x) | 0.047 s (0.05x) | 0.046 s (0.05x) |
| raytrace | 0.754 s | 0.850 s (1.13x) | 0.722 s (0.96x) | 0.749 s (0.99x) | 0.860 s (1.14x) | 0.678 s (0.90x) |
| sha256 | 1.009 s | 1.059 s (1.05x) | 1.012 s (1.00x) | 1.034 s (1.03x) | 1.139 s (1.13x) | 1.021 s (1.01x) |
| shapes | 0.884 s | 0.900 s (1.02x) | 0.870 s (0.98x) | 0.626 s (0.71x) | 0.549 s (0.62x) | 0.668 s (0.76x) |
| sieve | 0.601 s | 0.579 s (0.96x) | 0.583 s (0.97x) | 0.607 s (1.01x) | 0.664 s (1.10x) | 0.605 s (1.01x) |
| sort | 0.568 s | 0.576 s (1.01x) | 0.193 s (0.34x) | 0.053 s (0.09x) | 0.060 s (0.11x) | 0.054 s (0.09x) |
| spectral_norm | 0.973 s | 0.647 s (0.66x) | 0.954 s (0.98x) | 0.962 s (0.99x) | 0.962 s (0.99x) | 0.957 s (0.98x) |
| strings | 0.295 s | 0.293 s (1.00x) | 0.378 s (1.28x) | 0.246 s (0.83x) | 0.360 s (1.22x) | 0.239 s (0.81x) |
| vec_grow | 0.554 s | 0.560 s (1.01x) | 1.357 s (2.45x) | 0.592 s (1.07x) | 0.630 s (1.14x) | 0.566 s (1.02x) |
| vm_interp | 0.779 s | 0.853 s (1.10x) | 0.579 s (0.74x) | 0.688 s (0.88x) | 1.087 s (1.40x) | 0.794 s (1.02x) |
| wordfreq | 0.552 s | 0.559 s (1.01x) | 1.026 s (1.86x) | 0.598 s (1.08x) | 0.610 s (1.11x) | 0.589 s (1.07x) |
<!-- bench:end -->

## Reading the results

- **Most rows are a tie.** Volt compiles to the same machine code as C for the same loops: the C
  backend hands clang C that does what the C program does, and the LLVM backend emits the same IR
  clang would.
- **Release builds check bounds.** Indexing and slicing stay checked in `--release`, as one
  compare and a trap instruction ([safety](/volt-bootstrap/guide/safety/#release-builds)). Most
  rows don't notice: the compiler drops a check it can prove, and a loop over `0..xs.len` proves
  its own. The rows that index with values only known at run time pay: `vm_interp` (its stack
  pointer, local slots and program counter) is 1.02x where it was 0.62x unchecked, `dijkstra` 1.16x,
  `lz77` 1.12x. `@attributes([@unchecked])` on `vm_interp`'s `run` gives the unchecked time back
  (0.49 s). The gcc column pays more: gcc slows `bigint`'s addition loop down 3.4x for a check
  clang barely notices, still being looked into.
- **`sort`: a radix sort for integers.** `slice.sort` sorts integers of 256 or more elements by
  their bytes (it's stable, and integers have no order but their bits), in a few passes over the
  data, with no comparisons at all. `std::stable_sort` is a merge sort with the comparison inlined;
  C's `qsort` calls a function through a pointer for every comparison.
- **`vm_interp`: a `match` on an enum is a jump table.** A match whose arms test whole variants
  (no guards, no payload patterns) becomes a switch on the tag, and since the arms cover every tag
  it needs no default: LLVM copies the dispatch into the end of each arm, so each instruction jumps
  straight to the next one's code. C's `switch` keeps a range check and one shared dispatch;
  `std::visit` gets the same copied dispatch. Unchecked, Volt's is 0.62x and ahead of it; with the
  bounds checks above it's 1.02x.
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
  does what Volt does; Volt is ahead on the writing. A `println` takes stdout's lock once for the
  whole statement and puts its pieces into stdio's buffer with `fwrite_unlocked`, with no format
  string to parse, where C++ makes a `printf` call per line. It is still stdio's buffer, so a C
  library's `printf` output stays in order with Volt's.
- **gcc's own wins** are its optimizer's, and the **Volt (C, gcc)** column shows how much of them
  Volt's C output gets. `fib`: gcc turns much of the recursion into loops, for Volt's C as for the
  C program. `spectral_norm`: gcc vectorizes the inner loops at `-O2`, doing the divisions two at
  a time while keeping the sum in order (clang only vectorizes a float sum it may reorder); Volt's C
  gets most of that, since its `a(i, j)` does its math in `i32` as the C does (in `usize`, the
  unsigned 64-bit to `f64` conversion has no SSE2 vector form). `bigint`'s gcc win isn't Volt's yet.
- **Where Volt still trails**: `vm_interp`, `dijkstra` and `lz77` pay for their bounds checks
  (above). `lz77` and `wordfreq` also append to a `std::string` with a capacity check per call,
  where the C checks once per word and then writes without checks, and `wordfreq`'s `sort_by` (a
  stable merge sort) is a little slower than `qsort` on its 24-byte rows.
