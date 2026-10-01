---
title: Build files
description: Build logic written in Volt, with the bolt package's API.
sidebar:
  order: 6
---

A build file is an ordinary Volt program listed in `[build] files`. bolt builds and runs it before
building the package, and then does what it asked for. It uses the `bolt` package:

```toml
[build]
files = ["build.volt"]
```

```volt bolt
fn main() -> void {
    val mode = bolt::option("mode", "fast");       // bolt build -Dmode=small
    if (bolt::feature("turbo")) {                  // is this package's feature on?
        bolt::c_source("native/fast_math.c");      // compiled into every executable
    }
    bolt::link_c("m");                             // -lm
    bolt::exe("gen", "tools/gen.volt");            // one more executable
    bolt::step("assets");                          // bolt build assets
    bolt::run("assets", "gen", "--mode", mode);
    bolt::cmd("assets", "echo", "assets done");
}
```

Only the selected packages' build files run, never a dependency's.

## The API

| Function | |
| --- | --- |
| `bolt::option(name, fallback) -> str` | a `-Dname=value` from the command line, or the fallback |
| `bolt::feature(name) -> bool` | whether this package's feature is on |
| `bolt::profile() -> str` | the profile being built: `dev`, `release`, `test`, `bench` or a custom one |
| `bolt::exe(name, paths...)` | another executable, from `.volt` files and directories |
| `bolt::source(path)` | one more `.volt` file in every executable |
| `bolt::c_source(path)` | a C file compiled into every executable |
| `bolt::link_c(name)` | link a C library (`-lNAME`) into every executable |
| `bolt::cc_arg(arg)` | one more C compiler argument for every executable (`-I`, `-L`, `-D`, a library) |
| `bolt::step(name)` | a named step: `bolt build NAME` runs it |
| `bolt::cmd(step, program, args...)` | the step runs a program |
| `bolt::run(step, exe, args...)` | the step runs one of this package's executables (built first) |
| `bolt::depends(step, on)` | `step` runs after `on` (`"install"` builds every executable) |

Each call prints one `@bolt` line that bolt reads after the build file finishes; anything else a
build file prints is shown as it is. A step's program sees the C arguments the executables were
linked with (from `c_source`, `link_c` and `cc_arg`) in `$BOLT_CC_ARGS`, one per line, so a step
that builds more can use the same ones.

A dependency's build file counts too, like a Cargo build script's link lines: what its `c_source`,
`link_c` and `cc_arg` add goes into every program built on it, and its `-I`, `-D` and `-U` into the
compiles of its library and of every library that depends on it. That's how a package wrapping a C
library finds the library's headers and links it for whoever uses the package; `interop/python`
asks `python3-config`, for example.
