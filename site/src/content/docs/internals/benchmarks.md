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
| `revcomp` | the reverse complement of 64 MiB of DNA in FASTA lines of 60, nine times between two byte buffers (the Benchmarks Game) |
| `fasta` | generating 100 million bases of DNA, a repeated sequence and two drawn at random from cumulative probability tables built at compile time: a `comptime fn` against C++ `constexpr`, a Rust `const fn` and Zig `comptime` (C builds its tables at startup; the Benchmarks Game) |
| `huffman` | Huffman coding 32 MiB of text: the code tree from a priority queue (`std::heap` against a C heap, `std::priority_queue`, `BinaryHeap` and `std.PriorityQueue`) with optional children, the bits written and read back down the tree |
| `levenshtein` | edit distances between 40,000 pairs of strings of 64 to 191 letters, a dynamic program over one row |
| `life` | Conway's game of life on a 1024 by 1024 torus for 400 generations, a byte per cell |
| `fft` | a radix-2 FFT over a million complex doubles, there and back sixteen times (`attach operator` on a complex struct against C functions, `std::complex`, Rust's `Add` and `Mul` and Zig's `std.math.Complex`) |
| `btree` | an ordered map under 2 million inserts and lookups and 200,000 range scans: a B-tree generic over its key and value types, against `std::map` (a red-black tree) and Rust's `BTreeMap` |
| `sudoku` | backtracking over 13 hard sudoku puzzles relabelled at random 25 times: bit masks per row, column and box, the cell with the fewest candidates first |

The Rust and Zig programs use what those languages' standard libraries give, which isn't always the
same work as the C. Worth knowing when reading their columns:

- **Hash maps**: Rust's `HashMap` hashes with SipHash, which resists flooding and is slower than the
  multiply-and-shift or FNV hashes the C tables use; Zig's maps use Wyhash. That shows in
  `hashmap`, `knucleotide`, `wordfreq` and `lru_cache`, and it's the hash, not the language.
- **Allocation**: Rust's `Box` and `Vec` go through glibc's `malloc`, as C does; the Zig programs
  allocate through Zig's general-purpose allocator. In `lru_cache` the Rust and Zig versions reuse
  an evicted node's slot where C frees it and allocates a new one.
- **Bounds checks**: safe Rust checks every index (as Volt's release builds do, where the check can
  fail); C and Zig's ReleaseFast don't. `vm_interp` is where it costs most.
- **Library routines**: `sort` is each standard library's own sort (`slice::sort`, `std.mem.sort`),
  and `print` is Rust's own shortest-float formatting, where C's tries `%.*g` at each precision.
- **Target CPU**: Zig builds for the machine it runs on; clang, gcc, rustc and voltc build for any
  x86-64.

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
Measured 2026-10-09 on:

- **CPU**: AMD Ryzen 7 9800X3D 8-Core Processor (8 cores, 16 threads, `powersave` frequency governor)
- **Memory**: 60 GiB
- **OS**: Arch Linux, kernel 7.2.8-hardened1-2-hardened
- **C and C++**: clang version 23.1.1; gcc (GCC) 16.2.1 20260810
- **Rust**: rustc 1.99.0 (b940084d7 2026-09-28)
- **Zig**: zig 0.17.0
- **Volt**: voltc --release; its LLVM backend on LLVM 23.1.1
- **Timing**: best of 3 runs, wall clock

| Program | C (clang) | C (gcc) | C++ (clang++) | Rust (rustc) | Zig (ReleaseFast) | Volt (C, clang) | Volt (C, gcc) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bigint | 0.536 s | 0.444 s (0.83x) | 0.545 s (1.02x) | 0.624 s (1.16x) | 0.614 s (1.15x) | 0.453 s (0.85x) | 0.634 s (1.18x) | 0.451 s (0.84x) |
| binary_trees | 0.710 s | 0.649 s (0.91x) | 0.909 s (1.28x) | 1.130 s (1.59x) | 0.810 s (1.14x) | 0.336 s (0.47x) | 0.363 s (0.51x) | 0.287 s (0.40x) |
| btree | 0.448 s | 0.437 s (0.97x) | 1.681 s (3.75x) | 0.564 s (1.26x) | 0.473 s (1.05x) | 0.434 s (0.97x) | 0.436 s (0.97x) | 0.430 s (0.96x) |
| closures | 0.480 s | 0.739 s (1.54x) | 0.532 s (1.11x) | 0.568 s (1.18x) | 0.527 s (1.10x) | 0.536 s (1.12x) | 0.650 s (1.35x) | 0.471 s (0.98x) |
| crc32 | 0.708 s | 0.711 s (1.01x) | 0.716 s (1.01x) | 0.710 s (1.00x) | 0.708 s (1.00x) | 0.716 s (1.01x) | 0.770 s (1.09x) | 0.713 s (1.01x) |
| csv | 0.646 s | 0.650 s (1.01x) | 0.572 s (0.89x) | 0.409 s (0.63x) | 0.265 s (0.41x) | 0.306 s (0.47x) | 0.388 s (0.60x) | 0.367 s (0.57x) |
| dijkstra | 0.403 s | 0.503 s (1.25x) | 0.432 s (1.07x) | 0.296 s (0.74x) | 0.688 s (1.71x) | 0.387 s (0.96x) | 0.411 s (1.02x) | 0.381 s (0.95x) |
| errors | 0.670 s | 0.700 s (1.05x) | 1.311 s (1.96x) | 0.644 s (0.96x) | 0.779 s (1.16x) | 0.648 s (0.97x) | 0.728 s (1.09x) | 0.662 s (0.99x) |
| fannkuch | 1.846 s | 1.899 s (1.03x) | 1.911 s (1.04x) | 1.873 s (1.01x) | 2.051 s (1.11x) | 1.978 s (1.07x) | 1.688 s (0.91x) | 1.983 s (1.07x) |
| fasta | 0.860 s | 0.948 s (1.10x) | 0.850 s (0.99x) | 0.872 s (1.01x) | 0.865 s (1.01x) | 0.867 s (1.01x) | 0.856 s (1.00x) | 0.866 s (1.01x) |
| fft | 0.617 s | 0.648 s (1.05x) | 0.741 s (1.20x) | 0.654 s (1.06x) | 0.640 s (1.04x) | 0.624 s (1.01x) | 0.616 s (1.00x) | 0.693 s (1.12x) |
| fib | 0.449 s | 0.176 s (0.39x) | 0.451 s (1.00x) | 0.450 s (1.00x) | 0.447 s (1.00x) | 0.450 s (1.00x) | 0.165 s (0.37x) | 0.436 s (0.97x) |
| hashmap | 0.544 s | 0.547 s (1.00x) | 1.255 s (2.30x) | 0.602 s (1.11x) | 0.433 s (0.80x) | 0.469 s (0.86x) | 0.536 s (0.98x) | 0.463 s (0.85x) |
| heap | 0.594 s | 1.303 s (2.19x) | 0.594 s (1.00x) | 0.486 s (0.82x) | 0.776 s (1.31x) | 0.522 s (0.88x) | 0.574 s (0.97x) | 0.524 s (0.88x) |
| huffman | 0.767 s | 0.735 s (0.96x) | 0.606 s (0.79x) | 0.592 s (0.77x) | 1.039 s (1.35x) | 0.584 s (0.76x) | 0.803 s (1.05x) | 0.579 s (0.75x) |
| json | 0.650 s | 0.683 s (1.05x) | 0.592 s (0.91x) | 0.661 s (1.02x) | 0.597 s (0.92x) | 0.482 s (0.74x) | 0.647 s (0.99x) | 0.441 s (0.68x) |
| knucleotide | 0.744 s | 0.906 s (1.22x) | 0.737 s (0.99x) | 1.251 s (1.68x) | 0.801 s (1.08x) | 0.704 s (0.95x) | 1.064 s (1.43x) | 0.706 s (0.95x) |
| levenshtein | 0.582 s | 0.949 s (1.63x) | 0.447 s (0.77x) | 0.589 s (1.01x) | 0.476 s (0.82x) | 0.458 s (0.79x) | 0.973 s (1.67x) | 0.464 s (0.80x) |
| lexer | 0.553 s | 0.647 s (1.17x) | 0.750 s (1.36x) | 0.492 s (0.89x) | 0.464 s (0.84x) | 0.471 s (0.85x) | 0.557 s (1.01x) | 0.454 s (0.82x) |
| life | 0.809 s | 0.822 s (1.02x) | 0.785 s (0.97x) | 1.042 s (1.29x) | 0.768 s (0.95x) | 0.818 s (1.01x) | 0.674 s (0.83x) | 0.902 s (1.11x) |
| lru_cache | 0.569 s | 0.565 s (0.99x) | 1.292 s (2.27x) | 0.966 s (1.70x) | 1.006 s (1.77x) | 0.525 s (0.92x) | 0.758 s (1.33x) | 0.535 s (0.94x) |
| lz77 | 0.603 s | 0.581 s (0.96x) | 0.643 s (1.07x) | 0.642 s (1.06x) | 0.638 s (1.06x) | 0.692 s (1.15x) | 0.781 s (1.29x) | 0.684 s (1.13x) |
| mandelbrot | 0.638 s | 0.615 s (0.97x) | 0.639 s (1.00x) | 0.637 s (1.00x) | 0.629 s (0.99x) | 0.639 s (1.00x) | 0.618 s (0.97x) | 0.638 s (1.00x) |
| matmul | 0.508 s | 0.477 s (0.94x) | 0.505 s (0.99x) | 0.540 s (1.06x) | 0.844 s (1.66x) | 0.522 s (1.03x) | 1.028 s (2.02x) | 0.530 s (1.04x) |
| nbody | 0.701 s | 0.719 s (1.03x) | 0.681 s (0.97x) | 0.558 s (0.80x) | 0.454 s (0.65x) | 0.704 s (1.00x) | 0.768 s (1.10x) | 0.716 s (1.02x) |
| nqueens | 0.827 s | 0.815 s (0.99x) | 0.870 s (1.05x) | 0.817 s (0.99x) | 0.781 s (0.94x) | 0.840 s (1.02x) | 1.422 s (1.72x) | 0.831 s (1.01x) |
| print | 0.999 s | 1.008 s (1.01x) | 0.049 s (0.05x) | 0.044 s (0.04x) | 0.025 s (0.02x) | 0.046 s (0.05x) | 0.046 s (0.05x) | 0.046 s (0.05x) |
| raytrace | 0.757 s | 0.842 s (1.11x) | 0.720 s (0.95x) | 0.645 s (0.85x) | 0.598 s (0.79x) | 0.750 s (0.99x) | 0.856 s (1.13x) | 0.667 s (0.88x) |
| revcomp | 0.350 s | 0.338 s (0.97x) | 0.353 s (1.01x) | 0.592 s (1.69x) | 0.368 s (1.05x) | 0.374 s (1.07x) | 0.445 s (1.27x) | 0.424 s (1.21x) |
| sha256 | 1.005 s | 1.049 s (1.04x) | 0.998 s (0.99x) | 1.033 s (1.03x) | 1.190 s (1.18x) | 1.041 s (1.04x) | 1.141 s (1.14x) | 1.010 s (1.00x) |
| shapes | 0.874 s | 0.893 s (1.02x) | 0.869 s (1.00x) | 0.812 s (0.93x) | 0.848 s (0.97x) | 0.629 s (0.72x) | 0.545 s (0.62x) | 0.655 s (0.75x) |
| sieve | 0.597 s | 0.581 s (0.97x) | 0.591 s (0.99x) | 0.550 s (0.92x) | 0.551 s (0.92x) | 0.601 s (1.01x) | 0.628 s (1.05x) | 0.595 s (1.00x) |
| sort | 0.567 s | 0.553 s (0.97x) | 0.191 s (0.34x) | 0.106 s (0.19x) | 0.394 s (0.69x) | 0.052 s (0.09x) | 0.063 s (0.11x) | 0.064 s (0.11x) |
| spectral_norm | 0.980 s | 0.647 s (0.66x) | 0.936 s (0.96x) | 0.934 s (0.95x) | 0.949 s (0.97x) | 0.952 s (0.97x) | 0.950 s (0.97x) | 0.957 s (0.98x) |
| strings | 0.296 s | 0.291 s (0.98x) | 0.385 s (1.30x) | 0.264 s (0.89x) | 0.163 s (0.55x) | 0.259 s (0.88x) | 0.364 s (1.23x) | 0.252 s (0.85x) |
| sudoku | 0.744 s | 0.598 s (0.80x) | 0.764 s (1.03x) | 0.632 s (0.85x) | 0.710 s (0.96x) | 0.789 s (1.06x) | 0.629 s (0.85x) | 0.756 s (1.02x) |
| vec_grow | 0.592 s | 0.580 s (0.98x) | 1.395 s (2.36x) | 0.598 s (1.01x) | 0.605 s (1.02x) | 0.618 s (1.05x) | 0.651 s (1.10x) | 0.576 s (0.97x) |
| vm_interp | 0.781 s | 0.845 s (1.08x) | 0.581 s (0.74x) | 1.005 s (1.29x) | 0.994 s (1.27x) | 0.679 s (0.87x) | 1.096 s (1.40x) | 0.819 s (1.05x) |
| wordfreq | 0.540 s | 0.547 s (1.01x) | 1.033 s (1.91x) | 0.810 s (1.50x) | 0.471 s (0.87x) | 0.586 s (1.08x) | 0.644 s (1.19x) | 0.589 s (1.09x) |
<!-- bench:end -->

## Reading the results

- **Against Rust and Zig**: over the 39 programs Volt's LLVM build takes 0.88x Rust's time and 0.89x
  Zig's (geometric means; against C: Volt 0.81x, Rust 0.92x, Zig 0.91x). It's ahead on 24 programs
  against Rust and 21 against Zig, mostly from its allocator (`binary_trees`, `lru_cache`), its
  library (`sort`'s radix sort, `json`) and its hash maps against Rust's SipHash (`knucleotide`,
  `wordfreq`). Zig is ahead on `nbody`, `strings`, `csv`, `print`, `life` and `revcomp` (it also
  builds for this CPU, see above), and Rust on `dijkstra`, `nbody` and `sudoku`.

- **Most rows are a tie.** Volt compiles to the same machine code as C for the same loops: the C
  backend hands clang C that does what the C program does, and the LLVM backend emits the same IR
  clang would.
- **Release builds check bounds.** Indexing and slicing stay checked in `--release`, as one
  compare and a trap instruction ([safety](/volt-bootstrap/guide/safety/#release-builds)). Most
  rows don't notice: the compiler drops a check it can prove, and a loop over `0..xs.len` proves
  its own. The rows that index with values only known at run time pay: `vm_interp` (its stack
  pointer, local slots and program counter) is 1.05x where it was 0.62x unchecked, and `lz77`
  1.13x. `@attributes([@unchecked])` on `vm_interp`'s `run` gives the unchecked time back
  (0.49 s). `dijkstra` paid 1.16x until std's heap stopped checking the indices its sift loops
  can't get wrong; it's 0.95x now. The gcc column paid more on `bigint` (3.46x): an if value
  was a branch per arm storing its result, and gcc's jump threading copied the checked store in
  `rs[i] = if (over) x - BASE else x` into both arms of the branch on the carry, so the branch
  stayed and mispredicted where clang made it a conditional move. An if value whose arms are
  plain values is C's `?:` now, and `if (c) 1 else 0` is `c` as a number, so gcc makes the
  conditional move too: 0.82 s, then 0.64 s (1.43x of gcc's C, 0.45 s) once the program adds its
  limbs in the C's order and `resize`'s fill became a `memset`.
- **`sort`: a radix sort for integers.** `slice.sort` sorts integers of 256 or more elements by
  their bytes (it's stable, and integers have no order but their bits), in a few passes over the
  data, with no comparisons at all. `std::stable_sort` is a merge sort with the comparison inlined;
  C's `qsort` calls a function through a pointer for every comparison.
- **`vm_interp`: a `match` on an enum is a jump table.** A match whose arms test whole variants
  (no guards, no payload patterns) becomes a switch on the tag, and since the arms cover every tag
  it needs no default: LLVM copies the dispatch into the end of each arm, so each instruction jumps
  straight to the next one's code. C's `switch` keeps a range check and one shared dispatch;
  `std::visit` gets the same copied dispatch. Unchecked, Volt's is 0.62x and ahead of it; with the
  bounds checks above it's 1.05x.
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
  unsigned 64-bit to `f64` conversion has no SSE2 vector form). `bigint`'s gcc win isn't Volt's
  yet: Volt's C through clang matches gcc's C, so what's left is gcc on Volt's loops (the range
  loops' exit test hides from gcc that the index is in bounds), and the zeros `resize` writes that
  the C's `realloc` doesn't.
- **Where Volt still trails**: `vm_interp` and `lz77` pay for their bounds checks
  (above). `lz77` and `wordfreq` also append to a `std::string` with a capacity check per call,
  where the C checks once per word and then writes without checks, and `wordfreq`'s `sort_by` (a
  stable merge sort) is a little slower than `qsort` on its 24-byte rows.
