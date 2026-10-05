<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/volt-logo-dark.svg">
    <img alt="Volt" src="assets/logo/volt-logo-light.svg" width="340">
  </picture>
</p>

<p align="center">
  <b>A systems language with no runtime and nothing hidden.</b><br>
  <a href="https://chasesunstrom.github.io/volt-bootstrap/">Website</a> ·
  <a href="https://chasesunstrom.github.io/volt-bootstrap/start/install/">Install</a> ·
  <a href="https://chasesunstrom.github.io/volt-bootstrap/start/tour/">Tour</a> ·
  <a href="https://chasesunstrom.github.io/volt-bootstrap/guide/basics/">Language guide</a> ·
  <a href="https://chasesunstrom.github.io/volt-bootstrap/bolt/overview/">bolt</a>
</p>

Volt is a compiled language with no garbage collector, no vtables, no exceptions and no scheduler:
every call is resolved at compile time. Values are owned and deleted when their scope ends, errors
are values, generics are templates, and code can run in the compiler. It compiles to readable C or,
through LLVM, to native code; it reads C and C++ headers directly; and its compiler, `voltc`, is
written in Volt and builds itself.

## Why Volt

- **C's speed, nothing behind your back.** No GC, scheduler, exceptions or vtables; every
  allocation is one you wrote. On the [benchmarks](https://chasesunstrom.github.io/volt-bootstrap/internals/benchmarks/)
  Volt runs within a few percent of clang-compiled C.
- **Mistakes stop loudly until you ship.** Debug builds trap overflow, out-of-bounds indexing, null
  unwraps and double frees; the compiler rejects use after move, missed `match` cases and ignored
  errors. `--release` drops the run-time checks.
- **Ownership without lifetimes.** Values are deleted at scope end, moves are tracked and copies are
  explicit: RAII with nothing to annotate.
- **Every language is one step away.** It reads C and C++ headers (templates and the standard
  library too) and calls ordinary Rust crates, Zig files and Swift files directly, imported like a header
  (`use { "geom.rs" } as geom;`), builds Go code, and embeds Python, Java, .NET and Lua; one `bindings` line in
  `bolt.toml` makes a Volt library usable from 15 languages.
- **One toolchain.** bolt, a language server, and diagnostics that point at the problem.

It's young (no 1.0, no package registry) and has no borrow checker: if you need proven memory
safety, use Rust. The [Why Volt](https://chasesunstrom.github.io/volt-bootstrap/start/why/) page
has the details and a comparison with C, C++, Rust, Zig and Go.

```volt
use std::io;

error parse_error { EMPTY, BAD_DIGIT }

fn parse(s: str) -> parse_error!i32 {           // an error, or a value
    if (s.len == 0) {
        return parse_error::EMPTY;
    }
    var n = 0;
    for (ch) in s {
        if (ch < '0' || ch > '9') {
            return parse_error::BAD_DIGIT;
        }
        n = n * 10 + (ch - '0') as i32;         // overflow stops the program in debug builds
    }
    return n;
}

fn main() -> !void {
    val a = try parse("42");                    // try passes an error up
    val b = parse("4x") catch -1;               // catch handles it
    var seen: std::vec<i32> = {};               // owned: deleted at the end of main
    try seen.push(a);
    std::println("{} {} {}", a, b, seen.len);
}
// expect: 42 -1 1
```

## What's in it

- **Ownership** without a collector: deletes run at scope end, moves are tracked, copies are
  explicit, `box<T>` owns heap memory. A `val` can't change, even through a reference to it passed
  on, returned or stored in a struct.
- **Errors as values** (`E!T`, `try`, `catch`, `errdefer`) and **optionals** (`T?`, `??`, narrowing).
- **Templates** with specialization, packs and constant parameters; **traits** as constraints, and
  as tagged unions instead of vtables.
- **Comptime**: functions, `if`, `match` and `for` that run in the compiler, types as values,
  `@typeinfo`.
- **Async** as stackless frames of known size, driven by hand.
- **Two backends**: readable C, or native code through LLVM (the default on x86-64), with DWARF
  debug info for gdb in debug builds.
- **Embeddable, like Lua**: `libvoltvm` compiles Volt source in memory and runs it through LLVM's
  JIT, with host functions, sandboxes, and C, C++, Rust and Python bindings.
- **Bare metal with no C at all**: `--target riscv32-none`, `riscv64-none`, `thumbv6m-none`,
  `thumbv7m-none` or `thumbv7em-none` builds through LLVM and ld.lld with no C compiler, libc or C runtime.
- **A standard library** with collections, text, JSON, files, processes, networking, threads,
  allocators you choose per container, hashing and encodings.
- **Interop**: real C headers (unions and bitfields too), C++ classes, templates and the standard
  library, Rust crates, Zig files and Swift files imported by name (`use { "fm.zig" } as fm;`), Go modules through bolt,
  Python, Java, .NET and Lua through packages, and libraries with bindings for C, C++, Rust, Zig,
  Python, JavaScript and TypeScript, C#, Java, Go, Lua, Dart, Swift, Kotlin and Ruby.
- **Tooling**: diagnostics that point at the problem, the **bolt** build tool, a language server,
  and a VS Code extension.

## Build

You need stable Rust, a C compiler, and LLVM 22 with libclang (`llvm-c/` and `clang-c/` headers; on
Debian and Ubuntu, `llvm-22-dev` and `libclang-22-dev` from [apt.llvm.org](https://apt.llvm.org)).

```sh
cargo build --release                                        # voltc-bootstrap and bolt
cd voltc && ../target/release/bolt build --release && cd ..  # voltc, the compiler
export PATH="$PWD/voltc/target/release:$PWD/target/release:$PATH"   # for this shell; see the install guide
voltc run examples/tour.volt
```

Then `bolt new hello && cd hello && bolt run`. The
[install guide](https://chasesunstrom.github.io/volt-bootstrap/start/install/) has the details.

## Repository

| Path | |
| --- | --- |
| [`voltc/`](voltc) | the compiler, in Volt: checker, typed IR, C and LLVM backends, C/C++ import, language server; `voltc/embed` builds it into `libvoltvm`, Volt for embedding |
| [`bootstrap/`](bootstrap) | `voltc-bootstrap`, the stage0 compiler in Rust that builds voltc the first time |
| [`std/`](std) | the standard library, an ordinary package |
| [`runtime/`](runtime) | the small C prelude and runtime every program includes |
| [`bolt/`](bolt) | the build tool, and the API its build files use |
| [`editors/vscode/`](editors/vscode) | the VS Code extension |
| [`interop/`](interop) | `volt-build` (Cargo build scripts) and `volt.zig` (`build.zig`): Rust and Zig projects that use Volt; `python`, `java`, `dotnet` and `lua`: Volt programs that call Python, Java, .NET and Lua; `node`: Node.js addons written in Volt |
| [`site/`](site) | the website and documentation |
| [`examples/`](examples), [`tests/`](tests) | the tour and example programs; the test suites |
| [`assets/logo/`](assets/logo) | the logo, drawn by `logo.ts` |

## Testing

```sh
cargo test                  # goldens, compiler parity, bolt, interop, the language server, the docs
cd voltc && VOLTC=../target/release/voltc-bootstrap ../target/release/bolt build bootstrap
```

The second command is the bootstrap check: voltc rebuilds itself until two stages produce the same C,
then through LLVM, and runs the golden suite on both backends. See
[Internals](https://chasesunstrom.github.io/volt-bootstrap/internals/architecture/) and
[Contributing](https://chasesunstrom.github.io/volt-bootstrap/internals/contributing/).

## Status

Volt is young. The LLVM backend (the default on x86-64) has the System V calling convention only
for now, so Windows and aarch64 build through C; there's no package registry (bolt uses paths and
git). std's OS code has branches for macOS, FreeBSD and Windows, which the tests compile for each of
them, but they run on Linux only.

## License

Volt is licensed under either of the [MIT License](LICENSE-MIT) or the
[Apache License, Version 2.0](LICENSE-APACHE), at your option.
