---
title: Dependencies and features
description: Path and git dependencies, versions, bolt.lock, and features.
sidebar:
  order: 4
---

## Declaring dependencies

```toml
[dependencies]
geo = { path = "../geo" }
json = { git = "https://github.com/someone/json.git", tag = "v1.2" }
```

A dependency's library is reached by its name: `geo::distance(a, b)`. Dependencies are libraries
only; their programs, tests and build files never run for you.

bolt has no registry. Dependencies come from paths and git repositories:

- **path**: a directory with a bolt.toml.
- **git**: a repository, at a `rev`, a `branch` or a `tag` (default: its default branch). Git
  dependencies are cloned into `~/.cache/bolt` (`$BOLT_HOME`) and shared between projects.

`version = "..."` adds a check: the dependency's `[package] version` must meet the requirement.
`0.2` means `^0.2` (anything compatible), and `~`, `=`, `>`, `>=`, `<`, `<=`, `*` and lists like
`>=1.2, <2` work as in Cargo.

## bolt.lock

The first build records the exact commit of each git dependency in `bolt.lock`, next to the
workspace's root manifest; later builds use it, so a build is reproducible until you run
`bolt update`. `--locked` fails if the lock file would change, `--offline` never touches the network
(`bolt fetch` downloads everything first), and `--frozen` is both.

## Features

Features are named switches a package offers:

```toml
[features]
default = ["color"]
color = []
simd = ["dep:fastmath", "geo/simd"]

[dependencies]
fastmath = { path = "../fastmath", optional = true }
```

- A feature turns on other features, `dep:NAME` (an optional dependency) and `NAME/FEATURE` (a
  dependency's feature).
- `default` is on unless `--no-default-features`.
- `-F simd`, `--features app/simd`, `--all-features` on the command line.
- A dependency's features are the union of what everyone asks for.

Code reads its package's features at compile time:

```volt
use std::io;

fn greet() -> void {
    comptime if (@cfg("feature", "color")) {
        std::println("\x1b[33mhello\x1b[0m");
    } else {
        std::println("hello");
    }
}
```

A branch that's off isn't checked, so it can use an optional dependency that isn't there.

## Dev-dependencies

`[dev-dependencies]` are only for tests, examples and benchmarks.
