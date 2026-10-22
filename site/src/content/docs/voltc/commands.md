---
title: Commands and options
description: Every voltc command and flag.
sidebar:
  order: 1
---

`voltc` is the compiler. Every file named on the command line is part of one program.
`voltc-bootstrap`, the stage0 compiler, has only `run`, `build`, `check`, `emit-c` (to stdout),
`lib`, `std-dir` and `parse` (with `--dump`), and none of `--profiler`, `--shared`, `--static`,
`--lang`, `--backend`, `--target` or `--link-script`; it's frozen at what voltc's own sources use:
newer language features need voltc.

## Commands

| Command | What it does |
| --- | --- |
| `voltc run FILES... [-- ARGS]` | build and run; everything after `--` goes to the program. voltc exits with the program's code; when a signal ended it, voltc says which on stderr (`voltc: the program was ended by SIGSEGV (signal 11)`) and exits 128 + its number, as a shell does (on Windows it names a crash's status, such as `0xc0000005`, an access violation) |
| `voltc build FILES... [-o OUT]` | build an executable |
| `voltc check FILES...` | type check only |
| `voltc expand FILE[:LINE] [FILES...]` | what the comptime code in FILE (on LINE) became: values, `comptime if`/`match` branches, `comptime for` copies, generic instances, built types, the fns comptime fns declared and `@derive` output (self-hosted voltc) (see [Comptime](/volt-bootstrap/guide/comptime/#what-comptime-code-became-expand-and-voltc-expand)) |
| `voltc emit-c FILES... [-o DIR]` | print the generated C, or with `-o DIR` write it as separate files |
| `voltc emit-llvm FILES...` | print the LLVM IR (self-hosted voltc) |
| `voltc lib NAME [-o OUT]` | precompile package NAME's non-generic code into `libNAME.a` (see [Packages](/volt-bootstrap/voltc/packages/)) |
| `voltc bindings NAME --lang L` | bindings for package NAME's `export fn`s in another language (see `--lang`) |
| `voltc doc NAME` | package NAME's declarations and doc comments, as JSON |
| `voltc parse FILE --sexp` | print the parse tree, in a canonical text form |
| `voltc lsp` | the [language server](/volt-bootstrap/editors/lsp/) (it accepts the `--stdio` that LSP clients add) |
| `voltc std-dir` | print where the std package is |

## Options

| Flag | Effect |
| --- | --- |
| `--release` | optimize (`-O2`); drop the overflow and double-free checks, so integer overflow wraps; indexing, slicing, another variant's payload and `.value` stay checked, and a failed check traps (SIGILL on x86-64) instead of panicking; C compiled along gets `-fno-math-errno` (Volt never reads `errno`, so `sqrt` and friends become instructions); `@cfg("release")` is true |
| `--leak-check` | debug builds: exit with 102 if any allocation was never freed |
| `--test` | build the program's test blocks (`test "name" { ... }`) instead of its `main`: they run one by one through `std::testing`, and the program's argument picks them by name (see [Tests](/volt-bootstrap/bolt/testing/#test-blocks)) |
| `--test-pkg NAME` | with `--test`, package `NAME`'s test blocks too (it implies `--test`; no program files needed) |
| `--profiler` | build for [`bolt hot`](/volt-bootstrap/bolt/commands/#finding-the-hot-spots): line information, frame pointers, and a sampler that writes `$VOLT_PROFILE_OUT` when the program exits (Linux on x86-64 and aarch64). Through the C backend it's compiled with clang when that's installed and `$CC` isn't set: gcc leaves frame pointers out of leaf functions, which loses a leaf's caller |
| `--std DIR`, `--no-std` | the std package (default: `$VOLT_STD`, then a `std/` next to voltc) |
| `--pkg NAME=DIR` | a package: DIR's `.volt` files, in `namespace NAME` |
| `--link NAME=LIB.a` | take package NAME's non-generic code from a `voltc lib` build |
| `--cfg [PKG:]KEY[=VALUE]` | set KEY for `@cfg` in the program's files, or in package PKG's; `os`, `arch` and `pointer_bits` replace the host's in every package, for checking another platform's code ([the target](/volt-bootstrap/guide/comptime/#the-target)); building with another `arch` needs that arch's `--target`, or `--backend c` |
| `--lib NAME` | with `check`: check package NAME alone, as a library (no `main`) |
| `--shared`, `--static` | with `lib`: a self-contained `.so` (`.dylib`, `.dll`) or `.a` for other languages |
| `--lang L` | with `bindings`: `c`, `cpp`, `rust`, `zig`, `python`, `pyi`, `csharp`, `java`, `go`, `lua`, `dart`, `swift`, `kotlin`, `ruby`, `node`, `js`, `ts` or `json` |
| `--cc ARG` | pass ARG to the C compiler: a `.c` file, `-lNAME`, `-I`, `-D`... (repeatable); `-std=c11` or `-std=c++17` is the standard C or C++ imports are read and compiled under instead of the newest (Volt's own C, and `.c` files given here, under its GNU form) |
| `--backend c\|llvm` | self-hosted voltc: generate C, or native code through LLVM (the default on x86-64 and aarch64 but for Windows) |
| `--target T` | self-hosted voltc: build for bare metal (`riscv32-none`, `riscv64-none`, `thumbv6m-none`, `thumbv7m-none`, `thumbv7em-none`, `aarch64-none`) through LLVM, linked by `ld.lld` with no C compiler or C library; see [Bare metal](/volt-bootstrap/voltc/bare-metal/) |
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
| `BOLT` | the bolt that imports code in other languages but C and C++ (`use { "geom.rs" }`, `use { "fm.zig" }`, `use { "Geo.cs" }`...) (default: the bolt next to voltc, then `bolt` on the PATH) |
| `VOLT_CACHE` | where those imports keep their work (default `$XDG_CACHE_HOME/volt`, then `~/.cache/volt`) |
| `VOLT_SHOW_IMPORT` | `1`: print the Volt declarations generated for those imports |
| `VOLT_SHOW_SHIMS` | `1`: print the shims `voltc lib` adds in front of a package's export fns (their C forms) |
| `ZIG` | the zig that builds imported Zig code (default `zig`) |
| `VOLT_TRIPLE` | with `emit-llvm`: the LLVM triple to lower for instead of the host's (`aarch64-unknown-linux-gnu`, say) |

## Exit codes

`0` on success, `1` for compile errors (and an unknown option or a bad option value), `2` when it
prints the usage (no command, an unknown one, no files, or an option without its value). A program
built by voltc exits with what `main` returns, `1` when `main` returns an error, `101` on a panic
and `102` for a leak under `--leak-check`.
