---
title: Benchmarks
description: Volt against C, C++, Rust and Zig on the same programs, and how to run the comparison.
sidebar:
  order: 6
---

`bench/` has the same programs written in C, C++, Rust, Zig and Volt, each in the way that
language's programmers would usually write it: Rust and Zig with their standard libraries only
(safe Rust, no crates). Every program prints the same output in each language:

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

The harness builds each program eight ways. C is built with clang `-O2` and with gcc `-O2`, C++
with clang++ `-O2`, Rust with `rustc --edition 2024 -C opt-level=3`, and Zig with
`zig build-exe -O ReleaseFast` (which builds for the host CPU, Zig's default). Zig is found on
`PATH` or in `~/.local/bin`; without it the Zig column shows "—". Volt is built with `--release`
through both of voltc's backends: C, compiled by clang and by gcc, and LLVM. Each build runs best of
three, and every build has to print the same output.
`BENCH_ONLY=nbody,sort` runs only some of the programs, and `BENCH_RUNS=5` takes the best of five.
`BENCH_MAX_RATIO=1.25` fails when a Volt build takes more than 1.25 times as long as C (clang). A
full run rewrites the table below.

To see where one of them spends its time, run it under [`bolt hot`](/volt-bootstrap/bolt/commands/#finding-the-hot-spots):
`bolt hot bench/binary_trees/main.volt -- 18`.

## Results

A full run writes what follows: the machine and toolchain it ran on, then the times. Each time is
the best of the runs, and each one after C (clang) also shows its ratio to it (below 1.00x is
faster); "—" marks a compiler that wasn't installed. Times move a few percent between runs;
differences that small are noise.

<!-- bench:start -->
Measured 2026-10-06 on:

- **CPU**: AMD Ryzen 7 9800X3D 8-Core Processor (8 cores, 16 threads, `powersave` frequency governor)
- **Memory**: 60 GiB
- **OS**: Arch Linux, kernel 7.2.8-hardened1-2-hardened
- **C and C++**: clang version 23.1.1; gcc (GCC) 16.2.1 20260810
- **Rust**: rustc 1.99.0 (b940084d7 2026-09-28)
- **Zig**: zig 0.17.0
- **Volt**: voltc --release; its LLVM backend on LLVM 23.1.1
- **Timing**: best of 1 runs, wall clock

| Program | C (clang) | C (gcc) | C++ (clang++) | Rust (rustc) | Zig (ReleaseFast) | Volt (C, clang) | Volt (C, gcc) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bigint | 0.538 s | 0.446 s (0.83x) | 0.549 s (1.02x) | 0.638 s (1.18x) | 0.620 s (1.15x) | 0.550 s (1.02x) | 1.871 s (3.48x) | 0.558 s (1.04x) |
| binary_trees | 0.711 s | 0.666 s (0.94x) | 0.940 s (1.32x) | 1.122 s (1.58x) | 0.801 s (1.13x) | 0.362 s (0.51x) | 0.368 s (0.52x) | 0.294 s (0.41x) |
| closures | 0.484 s | 0.752 s (1.55x) | 0.533 s (1.10x) | 0.569 s (1.17x) | 0.536 s (1.11x) | 0.551 s (1.14x) | 0.671 s (1.39x) | 0.494 s (1.02x) |
| crc32 | 0.725 s | 0.719 s (0.99x) | 0.733 s (1.01x) | 0.719 s (0.99x) | 0.707 s (0.98x) | 0.708 s (0.98x) | 0.760 s (1.05x) | 0.712 s (0.98x) |
| csv | 0.672 s | 0.654 s (0.97x) | 0.581 s (0.86x) | 0.413 s (0.62x) | 0.270 s (0.40x) | 0.306 s (0.46x) | 0.391 s (0.58x) | 0.371 s (0.55x) |
| dijkstra | 0.439 s | 0.526 s (1.20x) | 0.472 s (1.08x) | 0.321 s (0.73x) | 0.709 s (1.62x) | 0.408 s (0.93x) | 0.426 s (0.97x) | 0.404 s (0.92x) |
| errors | 0.691 s | 0.707 s (1.02x) | 1.327 s (1.92x) | 0.737 s (1.07x) | 0.800 s (1.16x) | 0.642 s (0.93x) | 0.739 s (1.07x) | 0.672 s (0.97x) |
| fannkuch | 1.894 s | 1.924 s (1.02x) | 1.934 s (1.02x) | 1.900 s (1.00x) | 2.076 s (1.10x) | 1.986 s (1.05x) | 1.686 s (0.89x) | 1.986 s (1.05x) |
| fib | 0.449 s | 0.176 s (0.39x) | 0.451 s (1.00x) | 0.461 s (1.03x) | 0.449 s (1.00x) | 0.449 s (1.00x) | 0.167 s (0.37x) | 0.446 s (0.99x) |
| hashmap | 0.548 s | 0.567 s (1.04x) | 1.349 s (2.46x) | 0.628 s (1.15x) | 0.443 s (0.81x) | 0.480 s (0.88x) | 0.533 s (0.97x) | 0.467 s (0.85x) |
| heap | 0.595 s | 1.320 s (2.22x) | 0.598 s (1.01x) | 0.489 s (0.82x) | 0.775 s (1.30x) | 0.523 s (0.88x) | 0.587 s (0.99x) | 0.548 s (0.92x) |
| json | 0.657 s | 0.733 s (1.12x) | 0.608 s (0.93x) | 0.655 s (1.00x) | 0.639 s (0.97x) | 0.489 s (0.74x) | 0.675 s (1.03x) | 0.443 s (0.68x) |
| knucleotide | 0.748 s | 0.901 s (1.20x) | 0.743 s (0.99x) | 1.260 s (1.68x) | 0.786 s (1.05x) | 0.706 s (0.94x) | 1.050 s (1.40x) | 0.708 s (0.95x) |
| lexer | 0.551 s | 0.661 s (1.20x) | 0.760 s (1.38x) | 0.491 s (0.89x) | 0.465 s (0.85x) | 0.475 s (0.86x) | 0.555 s (1.01x) | 0.456 s (0.83x) |
| lru_cache | 0.588 s | 0.572 s (0.97x) | 1.316 s (2.24x) | 0.997 s (1.70x) | 1.015 s (1.73x) | 0.540 s (0.92x) | 0.779 s (1.32x) | 0.547 s (0.93x) |
| lz77 | 0.611 s | 0.583 s (0.95x) | 0.656 s (1.07x) | 0.650 s (1.06x) | 0.649 s (1.06x) | 0.694 s (1.14x) | 0.786 s (1.29x) | 0.677 s (1.11x) |
| mandelbrot | 0.638 s | 0.615 s (0.96x) | 0.641 s (1.00x) | 0.640 s (1.00x) | 0.647 s (1.01x) | 0.643 s (1.01x) | 0.628 s (0.98x) | 0.652 s (1.02x) |
| matmul | 0.527 s | 0.497 s (0.94x) | 0.527 s (1.00x) | 0.560 s (1.06x) | 0.870 s (1.65x) | 0.529 s (1.00x) | 1.061 s (2.01x) | 0.533 s (1.01x) |
| nbody | 0.712 s | 0.715 s (1.00x) | 0.686 s (0.96x) | 0.560 s (0.79x) | 0.458 s (0.64x) | 0.714 s (1.00x) | 0.775 s (1.09x) | 0.723 s (1.02x) |
| nqueens | 0.832 s | 0.810 s (0.97x) | 0.872 s (1.05x) | 0.827 s (1.00x) | 0.802 s (0.96x) | 0.853 s (1.03x) | 1.418 s (1.70x) | 0.832 s (1.00x) |
| print | 1.028 s | 1.026 s (1.00x) | 0.049 s (0.05x) | 0.046 s (0.04x) | 0.026 s (0.03x) | 0.046 s (0.04x) | 0.047 s (0.05x) | 0.051 s (0.05x) |
| raytrace | 0.768 s | 0.855 s (1.11x) | 0.737 s (0.96x) | 0.657 s (0.86x) | 0.607 s (0.79x) | 0.767 s (1.00x) | 0.887 s (1.16x) | 0.668 s (0.87x) |
| sha256 | 1.025 s | 1.067 s (1.04x) | 1.000 s (0.98x) | 1.043 s (1.02x) | 1.207 s (1.18x) | 1.040 s (1.02x) | 1.126 s (1.10x) | 1.013 s (0.99x) |
| shapes | 0.885 s | 0.903 s (1.02x) | 0.870 s (0.98x) | 0.815 s (0.92x) | 0.877 s (0.99x) | 0.645 s (0.73x) | 0.570 s (0.64x) | 0.673 s (0.76x) |
| sieve | 0.660 s | 0.593 s (0.90x) | 0.605 s (0.92x) | 0.563 s (0.85x) | 0.549 s (0.83x) | 0.606 s (0.92x) | 0.697 s (1.06x) | 0.608 s (0.92x) |
| sort | 0.572 s | 0.571 s (1.00x) | 0.193 s (0.34x) | 0.108 s (0.19x) | 0.400 s (0.70x) | 0.057 s (0.10x) | 0.059 s (0.10x) | 0.065 s (0.11x) |
| spectral_norm | 0.979 s | 0.656 s (0.67x) | 0.966 s (0.99x) | 0.975 s (1.00x) | 0.981 s (1.00x) | 0.972 s (0.99x) | 0.967 s (0.99x) | 0.986 s (1.01x) |
| strings | 0.295 s | 0.300 s (1.01x) | 0.382 s (1.29x) | 0.271 s (0.92x) | 0.164 s (0.56x) | 0.268 s (0.91x) | 0.371 s (1.26x) | 0.247 s (0.83x) |
| vec_grow | 0.571 s | 0.575 s (1.01x) | 1.427 s (2.50x) | 0.582 s (1.02x) | 0.620 s (1.09x) | 0.623 s (1.09x) | 0.665 s (1.16x) | 0.592 s (1.04x) |
| vm_interp | 0.806 s | 0.861 s (1.07x) | 0.598 s (0.74x) | 1.014 s (1.26x) | 1.001 s (1.24x) | 0.687 s (0.85x) | 1.077 s (1.34x) | 0.835 s (1.04x) |
| wordfreq | 0.567 s | 0.575 s (1.01x) | 1.040 s (1.83x) | 0.865 s (1.53x) | 0.488 s (0.86x) | 0.618 s (1.09x) | 0.631 s (1.11x) | 0.610 s (1.08x) |
<!-- bench:end -->

## Reading the results

- **Most rows are a tie.** Volt compiles to the same machine code as C for the same loops: the C
  backend hands clang C that does what the C program does, and the LLVM backend emits the same IR
  clang would.
- **Release builds check bounds.** Indexing and slicing stay checked in `--release`, as one
  compare and a trap instruction ([safety](/volt-bootstrap/guide/safety/#release-builds)). Most
  rows don't notice: the compiler drops a check it can prove, and a loop over `0..xs.len` proves
  its own. The rows that index with values only known at run time pay: `vm_interp` (its stack
  pointer, local slots and program counter) is 1.02x where it was 0.62x unchecked, and `lz77`
  1.15x. `@attributes([@unchecked])` on `vm_interp`'s `run` gives the unchecked time back
  (0.49 s). `dijkstra` paid 1.16x until std's heap stopped checking the indices its sift loops
  can't get wrong; it's 0.92x now. The gcc column pays more on `bigint` (3.49x): gcc's jump
  threading copies the checked store in `rs[i] = if (over) x - BASE else x` into both arms of
  the branch on the carry, so the branch stays and mispredicts, where clang makes it a
  conditional move.
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
- **Where Volt still trails**: `vm_interp` and `lz77` pay for their bounds checks
  (above). `lz77` and `wordfreq` also append to a `std::string` with a capacity check per call,
  where the C checks once per word and then writes without checks, and `wordfreq`'s `sort_by` (a
  stable merge sort) is a little slower than `qsort` on its 24-byte rows.
