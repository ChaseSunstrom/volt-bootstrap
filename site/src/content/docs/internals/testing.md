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
| `tests/diag.rs` | diagnostic snapshots: `tests/diag/NAME.volt` must print exactly `NAME.stderr` |
| `tests/selfhost.rs` | the two compilers agree (parse trees, diagnostics), the reviewed C output in `tests/cgen`, and the bootstrap |
| `tests/bolt.rs` | bolt end to end: packages, workspaces, git dependencies, features, build files |
| `tests/interop.rs` | Volt with C, C++, Rust, Zig and Python, both ways |
| `tests/lsp.rs` | a scripted session with `voltc lsp` |
| `tests/docs.rs` | every code block on this site compiles (and prints what it shows); the std reference is current |
| `tests/headers.rs` | every source file opens with a comment saying what it is |
| `tests/cc_env.rs` | `$CC` with a wrapper command or flags |

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

`editors/vscode` has its own tests (`npm test`: the grammar), and the site builds with a link
check (`npm run build`).
