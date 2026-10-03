---
title: Processes and the environment
description: "std::process: arguments, environment variables, the working directory, running other programs and collecting their output, and exiting."
sidebar:
  order: 4
---

## Arguments, the system and exiting

`std::process::arg(i)` is command-line argument `i`, or null past the last one; `arg(0)` is the
program itself and `arg_count()` counts them all. `os()` and `arch()` name the system and the CPU
the program was built for, the same names `@cfg("os", ...)` and `@cfg("arch", ...)` test at compile
time. `exit(code)` ends the program at once: it returns `never`, and scopes don't run their deletes
or defers on the way out, so return from `main` when there's cleanup to do.

```volt
use std::io;
use std::text;
use std::process;

fn main() -> void {
    val count = (std::process::arg(1) ?? "3").parse_int() catch 3;
    val program = std::process::arg(0) ?? "?";
    std::println("{} {} {}", count, program.len > 0, std::process::arg_count() >= 1);
    val os = std::process::os();
    std::println("{}", os == "linux" || os == "macos" || os == "windows" || os == "freebsd");
}
// expect: 3 true true
// expect: true
```

## The environment and the working directory

`env(name)` reads an environment variable, null when it isn't set; the `str` stays valid until
the environment changes. `set_env` and `unset_env` change it for this process and the programs it
starts. `cwd()` is the working directory as a `std::string`, `set_cwd` changes it, and
`exe_path()` is the path of the running program, with symlinks resolved (null where the system
won't say; Linux, macOS, FreeBSD and Windows do).

```volt
use std::io;
use std::process;

fn main() -> void {
    std::process::set_env("VOLT_DEMO", "on");
    std::println("{}", std::process::env("VOLT_DEMO") ?? "unset");
    std::process::unset_env("VOLT_DEMO");
    std::println("{}", std::process::env("VOLT_DEMO") ?? "unset");
    val here = std::process::cwd();
    std::println("{}", here.len() > 0);
}
// expect: on
// expect: unset
// expect: true
```

## Running programs

`run(argv)` starts a program, found on the `PATH` when `argv[0]` has no `/`, with the arguments
after it, and waits for it. It gives the exit code, or 128 plus the signal that stopped it.
`capture(argv, input)` also feeds it `input` as its standard input and collects what it prints:
an `output` with its `code`, `out` and `err`. Both fail with `SPAWN_FAILED` when the program can't
be started, as when it doesn't exist. Arguments go to the program as they are, with no shell in
between, so nothing in them needs quoting.

```volt
use std::io;
use std::process;

fn main() -> !void {
    val sort: str[1] = { "sort" };
    val r = try std::process::capture(sort[..], "pear\napple\nfig\n");
    std::print("{}", r.out);
    std::println("exit {}", r.code);
    val missing: str[1] = { "no-such-program-here" };
    val failed = std::process::run(missing[..]);
    std::println("{}", failed.err);
}
// expect: apple
// expect: fig
// expect: pear
// expect: exit 0
// expect: SPAWN_FAILED
```

These run programs on Linux, macOS and FreeBSD (fork and exec) and on Windows (`CreateProcessA`,
which looks for the program as Windows does: next to this one, in the working directory, in the
system's directories, then on `PATH`, adding `.exe`). A Windows program gets one command line, not
a list of arguments, so `run` and `capture` quote each argument the way the C runtime's parser reads
them back; `std::process::windows_args(argv)` gives that line, for code that starts programs some
other way. They refuse a `.bat` or `.cmd` (`SPAWN_FAILED`): those run through `cmd.exe`, which reads
the line by its own rules, so an argument could become a command. To run one, start `cmd.exe /c`
yourself and quote for it. The exit code of a program Windows ended (a crash) is its status, such as `-1073741819`
for an access violation, not 128 + a signal.
