---
title: bolt.toml reference
description: Every table and key bolt.toml accepts.
sidebar:
  order: 2
---

Unknown tables and keys are errors, so a typo never silently does nothing.

```toml
[package]
name = "app"                 # a Volt name: lowercase letters, digits, _ (it's the library's namespace)
version = "0.1.0"
description = "..."          # optional; also authors, license, repository
default-run = "app"          # which executable `bolt run` runs when there are several

[[bin]]                      # optional: by default one executable, named after the package, from src/
name = "app"
path = "src"                 # a directory or a file
required-features = []       # built only when these features are on

[lib]                        # optional: by default lib/, when it exists
path = "lib"
kind = ["volt"]              # also "shared" and "static": self-contained libraries for other languages
bindings = ["c", "python"]   # for other languages: c, cpp, rust, zig, python, pyi, csharp, java, go, lua, node, js, ts, json

[[example]]                  # also [[test]] and [[bench]]: name, path, required-features
name = "demo"
path = "examples/demo"

[dependencies]
geo = { path = "../geo", version = "0.2" }
json = { git = "https://example.com/json.git", tag = "v1.2" }
fast = { path = "../fast", optional = true, features = ["simd"], default-features = false }

[dev-dependencies]           # for tests, examples and benches only
testkit = { path = "../testkit" }

[features]
default = ["pretty"]
pretty = []
turbo = ["dep:fast", "geo/unrolled"]

[profile.release]            # tweak a built-in profile, or add your own
cc-flags = ["-march=native"]

[profile.small]
inherits = "release"

[std]                        # optional
path = "../mystd"            # or none = true for no std; prebuilt = false to skip std's .a

[build]
files = ["build.volt"]       # build files, run before building

[workspace]                  # makes this a workspace root
members = ["crates/*"]
```

## [package]

| Key | |
| --- | --- |
| `name` | required. The package's name and its library's namespace |
| `version` | required. `MAJOR.MINOR.PATCH` |
| `description`, `authors`, `license`, `repository` | optional metadata |
| `default-run` | the executable `bolt run` picks when there are several |

## Targets

`[[bin]]`, `[[example]]`, `[[test]]` and `[[bench]]` add targets beyond the conventional ones:

| Key | |
| --- | --- |
| `name` | the executable's name (letters, digits, `_`, `-`) |
| `path` | a `.volt` file or a directory of them; default `src` for a bin, `DIR/NAME` or `DIR/NAME.volt` for the others |
| `required-features` | features that must be on for it to be built |

## [lib]

| Key | |
| --- | --- |
| `path` | the library's directory (default `lib`) |
| `kind` | `"volt"` (the default: a `.a` for Volt programs), `"shared"`, `"static"` |
| `bindings` | languages to write bindings for: `c`, `cpp`, `rust`, `zig`, `python`, `pyi` (its type stubs), `csharp`, `java`, `go`, `node` (a Node-API addon's C, `NAME_node.c`), `js` (its loader), `ts` (its types, `NAME.d.ts`), `json` (the model) |

See [Other languages](/volt-bootstrap/interop/other-languages/).

## Dependencies

| Key | |
| --- | --- |
| `path` | a local package |
| `git` | a git repository, with at most one of `rev`, `branch`, `tag` |
| `version` | a requirement the dependency's version must meet: `0.2` (same as `^0.2`), `~1.4`, `=1.0.3`, `>=1.2, <2`, `1.*` |
| `optional` | only included when a feature turns it on (`dep:NAME`) |
| `features` | the dependency's features to turn on |
| `default-features` | `false` to leave its default features off |

## [features]

Each feature lists what it turns on: other features, `dep:NAME` (an optional dependency) and
`NAME/FEATURE` (a dependency's feature). `default` is on unless `--no-default-features` is given.
An optional dependency is also a feature of the same name. Code reads features with
`@cfg("feature", "NAME")`.

## [profile.NAME]

| Key | |
| --- | --- |
| `inherits` | the profile it starts from (required for a new profile) |
| `optimize` | `--release`: optimized, without debug checks |
| `leak-check` | `--leak-check` |
| `backend` | `"c"` or `"llvm"` |
| `cc-flags` | extra flags for the C compiler |

The built-in profiles are `dev` (target/debug), `release`, `test` (like dev) and `bench` (like
release). In a workspace, only the root's profiles count.

## [std]

| Key | |
| --- | --- |
| `path` | a different std package |
| `none` | `true`: build without std |
| `prebuilt` | `false`: compile std with the program instead of into its own `.a` |

## [build]

`files` lists [build files](/volt-bootstrap/bolt/build-files/), run before building.

## [workspace]

| Key | |
| --- | --- |
| `members` | member directories; globs like `crates/*` |
| `exclude` | directories the globs shouldn't pick up |
| `default-members` | what bolt works on when neither `-p` nor `--workspace` is given |

See [Workspaces](/volt-bootstrap/bolt/workspaces/).
