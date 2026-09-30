---
title: Bootstrapping
description: How voltc builds itself, and what the bootstrap check proves.
sidebar:
  order: 4
---

voltc is written in Volt, so building it needs a Volt compiler. The chain:

1. **voltc-bootstrap** (Rust, `cargo build`) compiles `voltc/src` to C: that's **stage1**.
2. **stage1** compiles `voltc/src` again: **stage2**.
3. **stage2** compiles it once more: **stage3**.

Stage2 and stage3 must generate exactly the same C for the compiler: a compiler that reproduces
itself. Then stage2 builds the compiler through LLVM, and that compiler must generate the same C
and the same LLVM IR as stage2. Libraries built by one backend are linked into programs built by
the other, and the golden test suite runs with stage2 on both backends.

The check is a bolt step in the voltc package:

```sh
cd voltc
VOLTC=../target/release/voltc-bootstrap ../target/release/bolt build bootstrap
```

and it runs in `cargo test` (`tests/selfhost.rs`, `bootstrap_reproduces_itself`).

## Keeping two compilers in step

The bootstrap compiler isn't a throwaway: it's the reference the self-hosted compiler is checked
against. `tests/selfhost.rs` requires the same parse tree for every `.volt` file in the repository
and the same diagnostics (text and exit code) for every test and example. So every change to the
language lands in both.
