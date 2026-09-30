---
title: Hello, Volt
description: A first program, with voltc and with bolt.
sidebar:
  order: 2
---

## One file

Save this as `hello.volt`:

```volt
use std::io;

fn main() -> void {
    val name = "Volt";
    std::println("Hello, {}!", name);
}
// expect: Hello, Volt!
```

and run it:

```sh
voltc run hello.volt
```

`use std::io;` makes `std::io`'s functions reachable as `std::name`, so `std::println` is
`std::io::println`. The format string is checked while compiling: each `{}` takes one argument, and
passing too few or too many is an error.

`voltc build hello.volt -o hello` makes an executable instead; `voltc check hello.volt` only type
checks. Every file on the command line is part of one program: `voltc run main.volt util.volt`.

## A bolt package

For anything bigger, let bolt manage the build:

```sh
bolt new hello
cd hello
bolt run
```

```
hello/
├── bolt.toml          the manifest: name, version, dependencies, features
└── src/
    └── main.volt      the program (every .volt file under src/ is part of it)
```

`bolt build --release` builds optimized, `bolt test` runs each program in `tests/`, and `bolt add`
adds dependencies. The [bolt section](/volt-bootstrap/bolt/overview/) covers all of it.

## What main returns

`main` returns `void`, an integer (the exit code), or an error union like `!void`: an error that
reaches the end of `main` prints its name and exits with 1.

```volt
use std::io;

error config_error { MISSING }

fn load() -> config_error!i32 {
    return config_error::MISSING;
}

fn main() -> !void {
    val n = try load();   // the error leaves main: it prints and the exit code is 1
    std::println("{}", n);
}
```

Next: [a tour of the language](/volt-bootstrap/start/tour/).
