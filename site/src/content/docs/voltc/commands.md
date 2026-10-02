---
title: Commands and options
description: Every voltc command and flag.
sidebar:
  order: 1
---

`voltc` is the compiler. Every file named on the command line is part of one program.
`voltc-bootstrap`, the stage0 compiler, takes the same commands except where noted.

## Commands

| Command | What it does |
| --- | --- |
| `voltc run FILES... [-- ARGS]` | build and run; everything after `--` goes to the program |
| `voltc build FILES... [-o OUT]` | build an executable |
| `voltc check FILES...` | type check only |
| `voltc emit-c FILES... [-o DIR]` | print the generated C, or with `-o DIR` write it as separate files |
| `voltc emit-llvm FILES...` | print the LLVM IR (self-hosted voltc) |
| `voltc lib NAME [-o OUT]` | precompile package NAME's non-generic code into `libNAME.a` (see [Packages](/volt-bootstrap/voltc/packages/)) |
| `voltc bindings NAME --lang L` | bindings for package NAME's `export fn`s in another language (see `--lang`) |
| `voltc doc NAME` | package NAME's declarations and doc comments, as JSON |
| `voltc parse FILE --sexp` | print the parse tree (used to compare the two compilers) |
| `voltc lsp` | the [language server](/volt-bootstrap/editors/lsp/) |
| `voltc std-dir` | print where the std package is |

## Options

| Flag | Effect |
| --- | --- |
| `--release` | optimize (`-O2`); drop the debug checks, so integer overflow wraps; C compiled along gets `-fno-math-errno` (Volt never reads `errno`, so `sqrt` and friends become instructions); `@cfg("release")` is true |
| `--leak-check` | debug builds: exit with 102 if any allocation was never freed |
| `--profiler` | build for [`bolt hot`](/volt-bootstrap/bolt/commands/#finding-the-hot-spots): line information, frame pointers, and a sampler that writes `$VOLT_PROFILE_OUT` when the program exits (Linux) |
| `--std DIR`, `--no-std` | the std package (default: `$VOLT_STD`, then a `std/` next to voltc) |
| `--pkg NAME=DIR` | a package: DIR's `.volt` files, in `namespace NAME` |
| `--link NAME=LIB.a` | take package NAME's non-generic code from a `voltc lib` build |
| `--cfg [PKG:]KEY[=VALUE]` | set KEY for `@cfg` in the program's files, or in package PKG's |
| `--lib NAME` | with `check`: check package NAME alone, as a library (no `main`) |
| `--shared`, `--static` | with `lib`: a self-contained `.so` or `.a` for other languages |
| `--lang L` | with `bindings`: `c`, `cpp`, `rust`, `zig`, `python`, `pyi`, `csharp`, `java`, `go`, `lua`, `dart`, `swift`, `kotlin`, `ruby`, `node`, `js`, `ts` or `json` |
| `--cc ARG` | pass ARG to the C compiler: a `.c` file, `-lNAME`, `-I`, `-D`... (repeatable) |
| `--backend c\|llvm` | self-hosted voltc: generate C (default) or native code through LLVM |
| `--target T` | self-hosted voltc: build for bare metal (`riscv32-none`, `riscv64-none`, `thumbv7m-none`, `thumbv7em-none`) through LLVM, linked by `ld.lld` with no C compiler or C library; see [Bare metal](/volt-bootstrap/voltc/bare-metal/) |
| `--link-script FILE` | the linker script for `--target`: the board's memory and the symbols the start code reads |
| `--message-format F` | `human` (default), `short` or `json`: see [Diagnostics](/volt-bootstrap/voltc/diagnostics/) |
| `--color WHEN` | `auto` (default), `always` or `never` |
| `--error-limit N` | show at most N errors, the first in source order (default 20; `0`: all) |
| `-o PATH` | output file (or directory, for `emit-c`) |

## Environment

| Variable | Used for |
| --- | --- |
| `VOLT_STD` | where std is, when `--std` isn't given |
| `CC` | the C compiler (default `cc`); it may be a command with words, like `ccache gcc` |
| `CXX` | the C++ compiler for the wrappers of imported C++ headers (default `c++`) |
| `VOLT_CLANG_RESOURCE_DIR` | libclang's resource directory, when `clang -print-resource-dir` can't find it |
| `NO_COLOR` | turn colour off (with `--color auto`) |
| `VOLT_SHOW_CPP` | `1`: print the Volt declarations generated from C++ headers |
| `BOLT` | the bolt that imports Rust and Zig code (`use { "geom.rs" }`, `use { "fm.zig" }`) (default: the bolt next to voltc, then `bolt` on the PATH) |
| `VOLT_CACHE` | where imports of Rust and Zig code keep their work (default `$XDG_CACHE_HOME/volt`, then `~/.cache/volt`) |
| `VOLT_SHOW_IMPORT` | `1`: print the Volt declarations generated for imported Rust and Zig code |
| `ZIG` | the zig that builds imported Zig code (default `zig`) |

## Exit codes

`0` on success, `1` for compile errors, `2` for a bad command line. A program built by voltc exits
with what `main` returns, `1` when `main` returns an error, `101` on a panic and `102` for a leak
under `--leak-check`.
