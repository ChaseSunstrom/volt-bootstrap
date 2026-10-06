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
- **LLVM 23** with its C headers, and **libclang** (`llvm-c/` and `clang-c/`). voltc links libLLVM
  for its LLVM backend and libclang to read C layouts and C++ headers. On Arch that's the `llvm` and
  `clang` packages. On Debian and Ubuntu, add LLVM's own apt repository and install the dev packages:

  ```sh
  wget https://apt.llvm.org/llvm.sh && sudo bash llvm.sh 23
  sudo apt install llvm-23-dev libclang-23-dev
  ```

  voltc's build asks `llvm-config` where LLVM is (`$LLVM_CONFIG`, else `llvm-config-23`, else
  `llvm-config` on your `PATH`), so it can live off the default paths, like Ubuntu's
  `/usr/lib/llvm-23`.
- Optional, for the interop tests: `c++`, `rustc`, `python3` and `zig`.

## Build

```sh
git clone https://github.com/ChaseSunstrom/volt-bootstrap volt
cd volt
cargo build --release                        # target/release/voltc-bootstrap and bolt
cd voltc && ../target/release/bolt build --release && cd ..   # voltc/target/release/voltc
```

The second step is bolt building the self-hosted compiler with the bootstrap one. Put both on your
`PATH`. Run this once, in the repository, so `$PWD` writes its full path into `~/.bashrc` (a `$PWD`
inside `~/.bashrc` itself would be wherever the shell starts):

```sh
echo "export PATH=\"$PWD/voltc/target/release:$PWD/target/release:\$PATH\"" >> ~/.bashrc
source ~/.bashrc
```

voltc finds the standard library by itself: a `std/` directory next to it or up to three levels
above (the repository's, from `voltc/target/release/`), or, for an installed toolchain, the
lib/volt/std that sits beside its bin directory. `$VOLT_STD` or `--std DIR` picks another. bolt runs `$VOLTC` when it's set, then a
`voltc` next to itself or on your `PATH`, then `voltc-bootstrap`.

## Check it

```sh
voltc run examples/tour.volt      # the language tour: it prints what each part does
cargo test                        # the whole suite: goldens, parity, bolt, interop, the site's code
```

Next, [write a first program](/volt-bootstrap/start/hello/).
