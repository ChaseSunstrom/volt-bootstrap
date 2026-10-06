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

## Stage 0 is frozen

The bootstrap compiler's one job is building stage1, so it's frozen: the language changes in
`voltc/src` alone, and the tests run stage1 (`tests/common/mod.rs` builds it once for a test run).
That holds as long as `voltc/src`, and the parts of std it uses, are written in what stage 0
compiles: a feature added since stays out of them. Every test run builds stage1 with stage 0, so
code stage 0 can't compile fails there first. The site's generator (`site/gen`) is under the same
rule, since the Pages workflow builds it with stage 0. A builtin attribute std puts on its own
declarations is the one change stage 0 still takes: it has to know the name to accept it (and
ignores it), as with `@invalidates`.
