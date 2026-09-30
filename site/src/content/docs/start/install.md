---
title: Install
description: Build the Volt compiler and bolt from source.
sidebar:
  order: 1
---

Volt is built from source. The first compiler, `voltc-bootstrap`, is written in Rust; it builds
`voltc`, the real compiler, which is written in Volt.

## What you need

- **Rust** (stable) and **a C compiler**: `cc` by default, or set `$CC` (`gcc`, `clang`, even
  `ccache gcc`).
- **LLVM 22** with its C headers, and **libclang** (`llvm-c/` and `clang-c/`). On Arch that's the
  `llvm` and `clang` packages; on Debian and Ubuntu, `llvm-22-dev` and `libclang-22-dev`. voltc links
  libLLVM for its LLVM backend and libclang to read C layouts and C++ headers.
- Optional, for the interop tests: `c++`, `rustc`, `python3` and `zig`.

## Build

```sh
git clone https://github.com/ChaseSunstrom/volt-bootstrap volt
cd volt
cargo build --release                        # target/release/voltc-bootstrap and bolt
cd voltc && ../target/release/bolt build --release && cd ..   # voltc/target/release/voltc
```

The second step is bolt building the self-hosted compiler with the bootstrap one. Put both on your
`PATH`, and tell voltc where the standard library is:

```sh
export PATH="$PWD/voltc/target/release:$PWD/target/release:$PATH"
export VOLT_STD="$PWD/std"
```

voltc also finds a `std/` directory next to itself (or in `../lib/volt/std`), so an installed
toolchain doesn't need `VOLT_STD`. bolt runs `$VOLTC` when it's set, then a `voltc` next to
itself or on your `PATH`, then `voltc-bootstrap`.

## Check it

```sh
voltc run examples/tour.volt      # the language tour: it prints what each part does
cargo test                        # the whole suite: goldens, parity, bolt, interop, the site's code
```

Next, [write a first program](/volt-bootstrap/start/hello/).
