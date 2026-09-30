---
title: Contributing
description: Conventions for working on Volt.
sidebar:
  order: 6
---

- **Both compilers.** A change to the language (syntax, checking, diagnostics) goes into
  `bootstrap/` and `voltc/src/`, and `tests/selfhost.rs` must pass. Features only the self-hosted
  compiler has (the LLVM backend, C++ import, the language server) live in `voltc/src` alone.
- **Both backends.** A change to code generation keeps the C and LLVM backends in agreement: run the
  bootstrap check.
- **std stays a library.** Nothing in the compiler may know std's names; what std needs from the
  compiler goes through `@intrinsic` and `@owns`, which any library can use.
- **Tests first.** A fix starts with a failing golden test (`tests/run`, `tests/fail`) or suite test.
- **Formatting.** `bootstrap/` isn't run through rustfmt; follow the style around the code you
  change. Comments say why, in plain words.
- **Docs.** A user-visible change updates this site (`site/src/content/docs`); its code blocks are
  compiled by `cargo test --test docs`, and `npm run build` in `site/` checks every link.

```sh
cargo build && cargo test
cd voltc && VOLTC=../target/debug/voltc-bootstrap ../target/debug/bolt build bootstrap
```
