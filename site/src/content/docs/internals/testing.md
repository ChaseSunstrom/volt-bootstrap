---
title: Testing
description: The test suites and what each one guards.
sidebar:
  order: 5
---

`cargo test` runs everything:

| Suite | What it checks |
| --- | --- |
| `tests/golden.rs` | every program in `tests/run` and `examples/` compiles, prints its `// expect:` lines and exits with its `// exit:` code; every file in `tests/fail` fails with its `// error:` texts |
| `tests/diag.rs` | diagnostic snapshots: each `.volt` file in `tests/diag` must print exactly the `.stderr` file of the same name |
| `tests/selfhost.rs` | the two compilers agree (parse trees, diagnostics), the reviewed C output in `tests/cgen`, and the bootstrap |
| `tests/bolt.rs` | bolt end to end: packages, workspaces, git dependencies, features, build files |
| `tests/interop.rs` | Volt with C, C++ (and its standard library), Rust, Zig, Python, Node, C#, Java, Go, Lua, Dart, Swift, Kotlin and Ruby, both ways, by hand and through bolt; and every example in `examples/interop` (its `run.sh` against its `expected.txt`) |
| `tests/lsp.rs` | a scripted session with `voltc lsp` |
| `tests/docs.rs` | every code block on this site compiles (and prints what it shows); the C and LLVM IR on the front page are what voltc writes; the std reference is current |
| `tests/site.rs` | the site's generator (`site/gen`, in Volt) builds every page with the theme's structure, and a link that goes nowhere fails the build |
| `tests/headers.rs` | every source file opens with a comment saying what it is |
| `tests/cc_env.rs` | `$CC` with a wrapper command or flags |
| `tests/bench.rs` | ignored by default: Volt against C and C++ on the programs in `bench/` (see [Benchmarks](/volt-bootstrap/internals/benchmarks/)) |

Golden files take directives in comments:

```volt
use std::io;
// flags: --release

fn main() -> i32 {
    std::println("hi");
    return 3;
}
// expect: hi
// exit: 3
```

`editors/vscode` has its own tests (`npm test`: the grammar).
