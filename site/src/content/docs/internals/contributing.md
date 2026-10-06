---
title: Contributing
description: Conventions for working on Volt.
sidebar:
  order: 6
---

- **One compiler.** A change to the language (syntax, checking, diagnostics) goes into `voltc/src`
  alone; the tests run stage1, voltc built by `bootstrap/`. The bootstrap is stage 0 and frozen: it
  only builds voltc, so `voltc/src`, the parts of std it uses and `site/gen` stay within what it
  compiles ([Bootstrapping](/volt-bootstrap/internals/bootstrap/)).
- **Both backends.** A change to code generation keeps the C and LLVM backends in agreement: run the
  bootstrap check.
- **std stays a library.** Nothing in the compiler may know std's names; what std needs from the
  compiler goes through `@intrinsic` and `@owns`, which any library can use.
- **Tests first.** A fix starts with a failing golden test (`tests/run`, `tests/fail`) or suite test.
- **Fuzzing.** `cargo test --test fuzz` checks 1500 broken variants of the test programs (`voltc
  check` must answer with diagnostics, never crash or hang) and runs 37 generated programs through
  both backends, debug and release (all four must print the same). `VOLT_FUZZ=20000` runs more and
  `VOLT_FUZZ_SEED=N` others; what fails stays in `target/tmp/fuzz` and `target/tmp/fuzz-backends`.
- **Formatting.** `bootstrap/` isn't run through rustfmt; follow the style around the code you
  change. Comments say why, in plain words.
- **Docs.** A user-visible change updates this site (`site/src/content/docs`); its code blocks are
  compiled by `cargo test --test docs`, and `cargo test --test site` builds it and checks every
  link. To look at it, build it into `site/dist` and serve that directory under `/volt-bootstrap/`:
  `voltc-bootstrap run site/gen/*.volt --std std -- site site/dist`.

```sh
cargo build && cargo test
cd voltc && VOLTC=../target/debug/voltc-bootstrap ../target/debug/bolt build bootstrap
```

CI (`.github/workflows/ci.yml`) runs on every push to main and every pull request:

- **Linux x86-64 and arm64:** the whole `cargo test`, with LLVM 23, lld, qemu and Node's types (for
  the TypeScript checks) installed. A build that warns fails. Failing tests are listed on the run's
  summary page. arm64 reports without failing the run until the LLVM backend runs on aarch64.
- **The editor extension:** its grammar and extension tests.
- **macOS (arm64, x86-64) and Windows (x86-64, arm64):** build the compilers and try running a few
  programs. These jobs are experimental and report without failing the run, since the test suite
  itself runs on Linux only for now.
