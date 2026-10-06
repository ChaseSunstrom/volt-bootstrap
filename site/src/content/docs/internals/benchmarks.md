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
Measured 2026-10-05 on:

- **CPU**: AMD Ryzen 7 9800X3D 8-Core Processor (8 cores, 16 threads, `powersave` frequency governor)
- **Memory**: 60 GiB
- **OS**: Arch Linux, kernel 7.2.8-hardened1-2-hardened
- **C and C++**: clang version 23.1.1; gcc (GCC) 16.2.1 20260810
- **Volt**: voltc --release; its LLVM backend on LLVM 23.1.1
- **Timing**: best of 3 runs, wall clock

| Program | C (clang) | C (gcc) | C++ (clang++) | Volt (C, clang) | Volt (C, gcc) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| bigint | 0.539 s | 0.445 s (0.83x) | 0.558 s (1.03x) | 0.545 s (1.01x) | 0.544 s (1.01x) | 0.553 s (1.03x) |
| binary_trees | 0.725 s | 0.664 s (0.92x) | 0.925 s (1.28x) | 0.363 s (0.50x) | 0.372 s (0.51x) | 0.288 s (0.40x) |
| closures | 0.478 s | 0.738 s (1.54x) | 0.535 s (1.12x) | 0.537 s (1.12x) | 0.653 s (1.37x) | 0.480 s (1.01x) |
| crc32 | 0.722 s | 0.712 s (0.99x) | 0.715 s (0.99x) | 0.715 s (0.99x) | 0.729 s (1.01x) | 0.722 s (1.00x) |
| csv | 0.658 s | 0.652 s (0.99x) | 0.587 s (0.89x) | 0.316 s (0.48x) | 0.346 s (0.53x) | 0.366 s (0.56x) |
| dijkstra | 0.448 s | 0.532 s (1.19x) | 0.486 s (1.09x) | 0.408 s (0.91x) | 0.452 s (1.01x) | 0.406 s (0.91x) |
| errors | 0.687 s | 0.695 s (1.01x) | 1.327 s (1.93x) | 0.665 s (0.97x) | 0.743 s (1.08x) | 0.673 s (0.98x) |
| fannkuch | 1.875 s | 1.893 s (1.01x) | 1.955 s (1.04x) | 1.998 s (1.07x) | 1.830 s (0.98x) | 1.991 s (1.06x) |
| fib | 0.450 s | 0.177 s (0.39x) | 0.450 s (1.00x) | 0.440 s (0.98x) | 0.171 s (0.38x) | 0.441 s (0.98x) |
| hashmap | 0.600 s | 0.594 s (0.99x) | 1.555 s (2.59x) | 0.506 s (0.84x) | 0.490 s (0.82x) | 0.499 s (0.83x) |
| heap | 0.600 s | 1.356 s (2.26x) | 0.606 s (1.01x) | 0.550 s (0.92x) | 0.609 s (1.01x) | 0.544 s (0.91x) |
| json | 0.664 s | 0.675 s (1.02x) | 0.598 s (0.90x) | 0.480 s (0.72x) | 0.646 s (0.97x) | 0.433 s (0.65x) |
| knucleotide | 0.746 s | 0.908 s (1.22x) | 0.733 s (0.98x) | 0.707 s (0.95x) | 0.850 s (1.14x) | 0.711 s (0.95x) |
| lexer | 0.563 s | 0.660 s (1.17x) | 0.753 s (1.34x) | 0.459 s (0.81x) | 0.544 s (0.97x) | 0.451 s (0.80x) |
| lru_cache | 0.574 s | 0.568 s (0.99x) | 1.318 s (2.29x) | 0.522 s (0.91x) | 0.584 s (1.02x) | 0.525 s (0.91x) |
| lz77 | 0.605 s | 0.587 s (0.97x) | 0.664 s (1.10x) | 0.648 s (1.07x) | 0.704 s (1.16x) | 0.650 s (1.08x) |
| mandelbrot | 0.639 s | 0.618 s (0.97x) | 0.641 s (1.00x) | 0.638 s (1.00x) | 0.624 s (0.98x) | 0.646 s (1.01x) |
| matmul | 0.516 s | 0.485 s (0.94x) | 0.513 s (0.99x) | 0.510 s (0.99x) | 0.855 s (1.66x) | 0.514 s (1.00x) |
| nbody | 0.712 s | 0.720 s (1.01x) | 0.680 s (0.96x) | 0.702 s (0.99x) | 0.772 s (1.09x) | 0.730 s (1.03x) |
| nqueens | 0.837 s | 0.813 s (0.97x) | 0.876 s (1.05x) | 0.852 s (1.02x) | 1.419 s (1.70x) | 0.837 s (1.00x) |
| print | 1.006 s | 1.015 s (1.01x) | 0.050 s (0.05x) | 0.045 s (0.04x) | 0.046 s (0.05x) | 0.045 s (0.04x) |
| raytrace | 0.757 s | 0.849 s (1.12x) | 0.735 s (0.97x) | 0.758 s (1.00x) | 0.877 s (1.16x) | 0.684 s (0.90x) |
| sha256 | 1.007 s | 1.070 s (1.06x) | 1.015 s (1.01x) | 1.047 s (1.04x) | 1.102 s (1.09x) | 1.014 s (1.01x) |
| shapes | 0.883 s | 0.901 s (1.02x) | 0.875 s (0.99x) | 0.635 s (0.72x) | 0.570 s (0.65x) | 0.675 s (0.77x) |
| sieve | 0.644 s | 0.628 s (0.97x) | 0.652 s (1.01x) | 0.642 s (1.00x) | 0.636 s (0.99x) | 0.636 s (0.99x) |
| sort | 0.580 s | 0.553 s (0.95x) | 0.197 s (0.34x) | 0.061 s (0.11x) | 0.064 s (0.11x) | 0.059 s (0.10x) |
| spectral_norm | 0.973 s | 0.650 s (0.67x) | 0.938 s (0.96x) | 0.970 s (1.00x) | 0.789 s (0.81x) | 0.980 s (1.01x) |
| strings | 0.299 s | 0.288 s (0.96x) | 0.402 s (1.34x) | 0.254 s (0.85x) | 0.388 s (1.30x) | 0.245 s (0.82x) |
| vec_grow | 0.565 s | 0.595 s (1.05x) | 1.461 s (2.59x) | 0.594 s (1.05x) | 0.591 s (1.05x) | 0.584 s (1.03x) |
| vm_interp | 0.790 s | 0.854 s (1.08x) | 0.580 s (0.73x) | 0.495 s (0.63x) | 0.813 s (1.03x) | 0.493 s (0.62x) |
| wordfreq | 0.574 s | 0.602 s (1.05x) | 1.052 s (1.83x) | 0.617 s (1.08x) | 0.593 s (1.03x) | 0.613 s (1.07x) |
<!-- bench:end -->

## Reading the results

- **Most rows are a tie.** Volt compiles to the same machine code as C for the same loops: the C
  backend hands clang C that does what the C program does, and the LLVM backend emits the same IR
  clang would.
- **`sort`: a radix sort for integers.** `slice.sort` sorts integers of 256 or more elements by
  their bytes (it's stable, and integers have no order but their bits), in a few passes over the
  data, with no comparisons at all. `std::stable_sort` is a merge sort with the comparison inlined;
  C's `qsort` calls a function through a pointer for every comparison.
- **`vm_interp`: a `match` on an enum is a jump table.** A match whose arms test whole variants
  (no guards, no payload patterns) becomes a switch on the tag, and since the arms cover every tag
  it needs no default: LLVM copies the dispatch into the end of each arm, so each instruction jumps
  straight to the next one's code. C's `switch` keeps a range check and one shared dispatch;
  `std::visit` gets the same copied dispatch, a little behind.
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
- **Where Volt still trails** by a few percent: `lz77` and `wordfreq`. Volt appends to a
  `std::string` with a capacity check per call, where the C checks once per word and then writes
  without checks, and `wordfreq`'s `sort_by` (a stable merge sort) is a little slower than `qsort`
  on its 24-byte rows.
