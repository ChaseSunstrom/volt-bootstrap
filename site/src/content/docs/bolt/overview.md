---
title: Getting started with bolt
description: What bolt does, a package's layout, and the everyday commands.
sidebar:
  order: 1
---

bolt is Volt's build tool: Cargo's workflow, without a registry. It builds packages and their
dependencies (local paths and git repositories, pinned in a lock file), with features, profiles,
tests, benchmarks and build files written in Volt.

```sh
bolt new app          # a program; bolt new --lib util for a library
cd app
bolt run              # build and run
bolt build --release  # optimized, into target/release/
bolt test             # build and run every program in tests/
```

## A package

A package is a directory with a `bolt.toml`:

```toml
[package]
name = "app"
version = "0.1.0"
```

and its sources, found by convention:

```
app/
├── bolt.toml
├── src/          the program: every .volt file here is one executable, `app`
├── lib/          the library: other packages call it as app::name
├── examples/     one program per .volt file or subdirectory (bolt run --example NAME)
├── tests/        one program per file; each must exit 0 (bolt test)
├── benches/      one program per file, built with the bench profile (bolt bench)
└── target/       build output: target/debug/, target/release/, ...
```

A package can have a program, a library, or both. Its library is in `namespace NAME`, the package's
name, for everyone including its own program.

## What a build does

bolt reads the manifest (and the workspace's, if it's in one), resolves dependencies and
`bolt.lock`, turns on features, then calls voltc: every library (std, each dependency, the
package's own `lib/`) is compiled once per profile into `target/<profile>/deps/libNAME.a`, in
parallel when they don't depend on each other, and rebuilt only when its sources, its settings or
voltc change. Executables are cached the same way.

bolt runs `$VOLTC` when set, otherwise a `voltc` next to itself or on `PATH`.

## Other languages

Both directions are a line in `bolt.toml`. `[lib] bindings = ["python", "node", ...]` writes the
library's bindings for those languages, and builds the ones that need compiling (a Node addon, Lua
and Ruby modules). `[foreign]` names a Rust crate or a Zig file the package uses: bolt builds it,
writes its C header and links it in. See the [bolt.toml reference](/volt-bootstrap/bolt/manifest/)
and [Rust and Zig](/volt-bootstrap/interop/rust-and-zig/).

## Next

- [bolt.toml reference](/volt-bootstrap/bolt/manifest/)
- [Commands](/volt-bootstrap/bolt/commands/)
- [Dependencies and features](/volt-bootstrap/bolt/dependencies/)
- [Workspaces and profiles](/volt-bootstrap/bolt/workspaces/)
- [Build files](/volt-bootstrap/bolt/build-files/)
- [Tests, examples and benchmarks](/volt-bootstrap/bolt/testing/)
