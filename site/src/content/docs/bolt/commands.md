---
title: Commands
description: Every bolt command and option.
sidebar:
  order: 3
---

## Building

| Command | |
| --- | --- |
| `bolt build [STEP] [-Dname=value]` | build the package; with STEP, run that build-file step. `-D` sets build-file options |
| `bolt check` | type-check the library and executables without building (`--all-targets`: tests, examples and benchmarks too) |
| `bolt run [-- ARGS]` | build and run an executable (`--bin NAME`, `--example NAME`) |
| `bolt test [FILTER]` | build and run the tests (`--no-run` builds only) |
| `bolt bench [FILTER]` | build the benchmarks with the bench profile and time them |
| `bolt hot [FILES] [-- ARGS]` | run the executable (or `.volt` FILES) sampled, and show where it spends its time |
| `bolt clean` | remove `target/` (with `--release` or `--profile`, only that profile's) |

### Finding the hot spots

`bolt hot` builds an optimized, sampled copy of the program (in `target/hot/`, apart from the
normal builds), runs it, and reports the hottest functions (their own time and with what they
call), the hottest `.volt` lines, and the hottest call paths. Code that got inlined counts where
it's written, and time spent in a shared library (libc's `malloc`, say) is named too.

```
$ bolt hot bench/closures/main.volt -- 300
bolt hot: 200 samples of /tmp/bolt-hot-4242/main

  self   total  function
 45.5%   99.0%  pipeline<closure(i64) -> i64, closure(i64) -> bool> (bench/closures/main.volt:6), inlined
 40.5%   40.5%  a closure (bench/closures/main.volt:30:92), inlined
 13.0%   13.0%  a closure (bench/closures/main.volt:30:39), inlined
  1.0%  100.0%  main (bench/closures/main.volt:18), inlined

hottest lines
 53.5%  bench/closures/main.volt:30  total += pipeline(xs.items(), |factor| (x: i64) -> i64 { return x *...
 35.0%  bench/closures/main.volt:12  sum += y;
 10.5%  bench/closures/main.volt:9  for (x) in xs {

hottest paths
 45.5%  main -> pipeline<closure(i64) -> i64, closure(i64) -> bool>
 40.5%  main -> pipeline<closure(i64) -> i64, closure(i64) -> bool> -> closure@main.volt:30:92
```

`inlined` marks a function that every sample found inlined into its callers: its self time is spent
at its lines there, not in calls to it. A C compiler's copies of a function
(`work.constprop.0`, made for a constant argument) are reported as that function.

The program samples itself (on each tick of the kernel's timer, usually 250 to 1000 times a second
of CPU time), so this needs no `perf`, debugger or root; it runs on Linux (x86-64 and aarch64), and
names the samples with `llvm-symbolizer` or `addr2line`. Run the program long enough to get a few
hundred samples.

## Packages

| Command | |
| --- | --- |
| `bolt new PATH [--lib]` | a new package in a new directory (a git repository too, unless `--vcs none` or it's inside one) |
| `bolt init [PATH] [--lib]` | a package in an existing directory |
| `bolt add [NAME] --path DIR` | add a dependency; or `--git URL [--rev R \| --branch B \| --tag T]`; `NAME@REQ` adds a version requirement |
| `bolt remove NAME...` | remove dependencies (`--dev`: from `[dev-dependencies]`) |
| `bolt update [NAME...]` | move git dependencies to their newest commits |
| `bolt fetch` | download every git dependency, for `--offline` builds later |
| `bolt tree` | print the dependency tree |
| `bolt metadata` | the workspace as JSON: packages, targets, dependencies, features |
| `bolt install [--path DIR]` | build with the release profile and copy the executables to `~/.local/bin` (or `--git URL`, at a `--rev`, `--branch` or `--tag`; `--root DIR`, `$BOLT_INSTALL_ROOT`; `--bin NAME` picks some, `--force` replaces ones already there) |
| `bolt uninstall NAME...` | remove what `install` put there |

`bolt add` also takes `--dev`, `--optional`, `--features A,B` and `--no-default-features`. `add`
and `remove` edit bolt.toml in place, keeping its comments and layout. `bolt new` and `bolt init`
name the package after its directory (lowercased, `-` as `_`) unless `--name NAME` says otherwise.

## Options

| Option | |
| --- | --- |
| `-p, --package NAME` | work on this package (default: the one here, or the workspace's default members) |
| `--workspace`, `--all` | every package in the workspace |
| `-r, --release` | the release profile |
| `--profile NAME` | any profile |
| `-F, --features LIST` | turn on features: `NAME`, `PACKAGE/NAME`, `DEPENDENCY/NAME` |
| `--all-features`, `--no-default-features` | |
| `--bin NAME`, `--bins`, `--example(s)`, `--test(s)`, `--bench(es)`, `--lib`, `--all-targets` | which targets |
| `-j, --jobs N` | parallel compiles (default: one per CPU) |
| `--target-dir DIR` | build somewhere other than `target/` |
| `--manifest-path PATH` | the bolt.toml to use |
| `--locked`, `--offline`, `--frozen` | refuse to change `bolt.lock` / to use the network / both |
| `--backend c\|llvm` | override the profile's backend |
| `--message-format F`, `--color WHEN`, `--error-limit N` | passed to voltc |
| `-q, --quiet`, `-v, --verbose` | fewer or more lines (verbose prints each command). On a terminal, a live `Building` line under the others shows what's compiling and for how long |
| `-V, --version`, `-h, --help` | print bolt's version, or its usage |

Options go before or after the command, and `--option=value` works too. `b`, `c`, `r`, `t` and `rm`
are short for `build`, `check`, `run`, `test` and `remove`.

## Environment

| Variable | |
| --- | --- |
| `VOLTC` | the compiler bolt runs |
| `BOLT_HOME` | where git dependencies are cloned (default `$XDG_CACHE_HOME/bolt`, else `~/.cache/bolt`) |
| `BOLT_INSTALL_ROOT` | where `install` puts executables (`ROOT/bin`) |
| `BOLT_API` | the `bolt` package build files use (default: `api/` next to bolt, the checkout's `bolt/api`, or `lib/volt/bolt` beside its `bin/`) |
| `CARGO`, `ZIG`, `GO`, `CC` | what builds `[foreign]` libraries and the Node, Lua and Ruby modules (defaults `cargo`, `zig`, `go`, `cc`) |
