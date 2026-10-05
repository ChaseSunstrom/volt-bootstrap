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
Measured 2026-10-05 on:

- **CPU**: AMD Ryzen 7 9800X3D 8-Core Processor (8 cores, 16 threads, `powersave` frequency governor)
- **Memory**: 60 GiB
- **OS**: Arch Linux, kernel 7.2.8-hardened1-2-hardened
- **C and C++**: clang version 23.1.1; gcc (GCC) 16.2.1 20260810
- **Volt**: voltc --release; its LLVM backend on LLVM 23.1.1
- **Timing**: best of 3 runs, wall clock

| Program | C (clang) | C (gcc) | C++ (clang++) | Volt (C backend) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: |
| bigint | 0.536 s | 0.446 s (0.83x) | 0.543 s (1.01x) | 0.546 s (1.02x) | 0.545 s (1.02x) |
| binary_trees | 0.707 s | 0.660 s (0.93x) | 0.914 s (1.29x) | 0.348 s (0.49x) | 0.282 s (0.40x) |
| closures | 0.472 s | 0.734 s (1.56x) | 0.533 s (1.13x) | 0.534 s (1.13x) | 0.480 s (1.02x) |
| crc32 | 0.711 s | 0.709 s (1.00x) | 0.702 s (0.99x) | 0.701 s (0.99x) | 0.702 s (0.99x) |
| csv | 0.651 s | 0.648 s (1.00x) | 0.568 s (0.87x) | 0.342 s (0.53x) | 0.363 s (0.56x) |
| dijkstra | 0.434 s | 0.507 s (1.17x) | 0.443 s (1.02x) | 0.514 s (1.18x) | 0.500 s (1.15x) |
| errors | 0.682 s | 0.700 s (1.03x) | 1.322 s (1.94x) | 0.655 s (0.96x) | 0.660 s (0.97x) |
| fannkuch | 1.858 s | 1.903 s (1.02x) | 1.935 s (1.04x) | 1.969 s (1.06x) | 1.992 s (1.07x) |
| fib | 0.449 s | 0.175 s (0.39x) | 0.452 s (1.00x) | 0.438 s (0.97x) | 0.433 s (0.96x) |
| hashmap | 0.545 s | 0.569 s (1.04x) | 1.342 s (2.46x) | 0.548 s (1.01x) | 0.570 s (1.05x) |
| heap | 0.599 s | 1.343 s (2.24x) | 0.600 s (1.00x) | 0.610 s (1.02x) | 0.617 s (1.03x) |
| json | 0.639 s | 0.655 s (1.03x) | 0.570 s (0.89x) | 0.484 s (0.76x) | 0.442 s (0.69x) |
| knucleotide | 0.743 s | 0.904 s (1.22x) | 0.737 s (0.99x) | 1.045 s (1.41x) | 1.054 s (1.42x) |
| lexer | 0.554 s | 0.657 s (1.19x) | 0.748 s (1.35x) | 0.493 s (0.89x) | 0.461 s (0.83x) |
| lru_cache | 0.571 s | 0.563 s (0.99x) | 1.307 s (2.29x) | 1.023 s (1.79x) | 1.019 s (1.78x) |
| lz77 | 0.605 s | 0.578 s (0.96x) | 0.640 s (1.06x) | 0.697 s (1.15x) | 0.682 s (1.13x) |
| mandelbrot | 0.637 s | 0.616 s (0.97x) | 0.638 s (1.00x) | 0.638 s (1.00x) | 0.639 s (1.00x) |
| matmul | 0.515 s | 0.476 s (0.92x) | 0.510 s (0.99x) | 0.513 s (1.00x) | 0.511 s (0.99x) |
| nbody | 0.698 s | 0.714 s (1.02x) | 0.681 s (0.97x) | 0.699 s (1.00x) | 0.727 s (1.04x) |
| nqueens | 0.831 s | 0.803 s (0.97x) | 0.866 s (1.04x) | 0.847 s (1.02x) | 0.832 s (1.00x) |
| print | 1.012 s | 1.008 s (1.00x) | 0.048 s (0.05x) | 0.043 s (0.04x) | 0.044 s (0.04x) |
| raytrace | 0.753 s | 0.848 s (1.13x) | 0.719 s (0.95x) | 0.747 s (0.99x) | 0.666 s (0.88x) |
| sha256 | 1.016 s | 1.038 s (1.02x) | 1.000 s (0.98x) | 1.026 s (1.01x) | 1.005 s (0.99x) |
| shapes | 0.882 s | 0.896 s (1.02x) | 0.873 s (0.99x) | 0.631 s (0.71x) | 0.673 s (0.76x) |
| sieve | 0.588 s | 0.585 s (0.99x) | 0.596 s (1.01x) | 0.605 s (1.03x) | 0.596 s (1.01x) |
| sort | 0.559 s | 0.696 s (1.24x) | 0.191 s (0.34x) | 0.233 s (0.42x) | 0.228 s (0.41x) |
| spectral_norm | 0.969 s | 0.648 s (0.67x) | 0.936 s (0.97x) | 0.946 s (0.98x) | 0.936 s (0.97x) |
| strings | 0.294 s | 0.285 s (0.97x) | 0.374 s (1.27x) | 0.258 s (0.88x) | 0.264 s (0.90x) |
| vec_grow | 0.559 s | 0.553 s (0.99x) | 1.335 s (2.39x) | 0.546 s (0.98x) | 0.551 s (0.99x) |
| vm_interp | 0.781 s | 0.848 s (1.09x) | 0.582 s (0.74x) | 0.924 s (1.18x) | 0.913 s (1.17x) |
| wordfreq | 0.548 s | 0.563 s (1.03x) | 1.003 s (1.83x) | 0.712 s (1.30x) | 0.705 s (1.29x) |
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
  does what Volt does; Volt is ahead on the writing. A `println` takes stdout's lock once for the
  whole statement and puts its pieces into stdio's buffer with `fwrite_unlocked`, with no format
  string to parse, where C++ makes a `printf` call per line. It is still stdio's buffer, so a C
  library's `printf` output stays in order with Volt's.
- **gcc's own wins** (`fib`, `spectral_norm`) are its optimizer's: it turns much of `fib`'s
  recursion into loops. Volt's C backend is compiled by clang here, so it follows clang.
