---
title: Workspaces and profiles
description: Several packages built together, and profiles for how they're built.
sidebar:
  order: 5
---

## Workspaces

A workspace is a bolt.toml with a `[workspace]` table. Its members share one `target/`, one
`bolt.lock` and the root's profiles.

```toml
[workspace]
members = ["crates/*", "tools/gen"]
exclude = ["crates/experimental"]
default-members = ["crates/app"]
```

The root can be a package too (with its own `[package]`), or only a workspace. Inside a member,
bolt finds the workspace above it.

| | |
| --- | --- |
| `bolt build` | the default members (or the package you're in) |
| `bolt build -p NAME` | one member |
| `bolt build --workspace` | all of them |

Members depend on each other with path dependencies.

## Profiles

A profile says how to build: optimized or not, with the leak check, with which backend, and with
which extra C flags. Its output goes to `target/<dir>/`.

| Profile | Like | Directory |
| --- | --- | --- |
| `dev` | debug checks on | `target/debug` |
| `release` | optimized | `target/release` |
| `test` | `dev` | `target/debug` |
| `bench` | `release` | `target/release` |

Change one, or define your own with `inherits`:

```toml
[profile.dev]
leak-check = true

[profile.release]
backend = "llvm"
cc-flags = ["-march=native"]

[profile.small]
inherits = "release"
cc-flags = ["-Os"]
```

`bolt build --profile small` builds into `target/small/`. `--release` is short for
`--profile release`.
