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

## Results

Times are the best of three on the machine that last ran the full suite. Each Volt time also shows
its ratio to C (clang).

<!-- bench:start -->
| Program | C (clang) | C (gcc) | C++ (clang++) | Volt (C backend) | Volt (LLVM) |
| --- | ---: | ---: | ---: | ---: | ---: |
| binary_trees | 0.708 s | 0.654 s (0.92x) | 0.957 s (1.35x) | 0.842 s (1.19x) | 0.810 s (1.14x) |
| closures | 0.474 s | 0.734 s (1.55x) | 0.532 s (1.12x) | 0.567 s (1.20x) | 0.468 s (0.99x) |
| fannkuch | 1.906 s | 1.904 s (1.00x) | 1.935 s (1.02x) | 1.961 s (1.03x) | 1.939 s (1.02x) |
| hashmap | 0.534 s | 0.543 s (1.02x) | 1.216 s (2.28x) | 0.539 s (1.01x) | 0.525 s (0.98x) |
| mandelbrot | 0.639 s | 0.615 s (0.96x) | 0.637 s (1.00x) | 0.637 s (1.00x) | 0.638 s (1.00x) |
| nbody | 0.717 s | 0.717 s (1.00x) | 0.680 s (0.95x) | 0.716 s (1.00x) | 0.728 s (1.02x) |
| sort | 0.608 s | 0.561 s (0.92x) | 0.190 s (0.31x) | 0.227 s (0.37x) | 0.227 s (0.37x) |
| spectral_norm | 0.959 s | 0.648 s (0.68x) | 0.935 s (0.97x) | 0.937 s (0.98x) | 0.936 s (0.98x) |
| strings | 0.281 s | 0.284 s (1.01x) | 0.381 s (1.36x) | 0.252 s (0.90x) | 0.267 s (0.95x) |
<!-- bench:end -->
