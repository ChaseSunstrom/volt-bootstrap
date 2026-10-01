---
title: Why Volt
description: What Volt is for, how it compares with C, C++, Rust, Zig and Go, and when to pick something else.
sidebar:
  order: 0
---

Volt is for code where you want C's control and speed, and none of C's guessing: what a line does is
what it looks like it does, the compiler catches what it can, and debug builds catch the rest.

## What you get

**C's speed, with nothing running behind you.** There's no garbage collector, scheduler, exception
unwinder or vtable. Every call is resolved when compiling, and every allocation is one you wrote.
On the [benchmarks](/volt-bootstrap/internals/benchmarks/) Volt runs within a few percent of
clang-compiled C, and beats it where templates inline what C does through function pointers (`sort`
takes less than half C's time).

**Mistakes stop, loudly, until you ship.** Debug builds check what C leaves undefined: integer
overflow, out-of-bounds indexing, null unwraps and double frees stop the program and name the line.
`--release` drops the checks. The compiler rejects use after move, a `match` that misses a case,
an ignored error and a format string that doesn't fit its arguments. See
[Safety checks](/volt-bootstrap/guide/safety/).

**Ownership without a fight.** Every value has one owner and is deleted when that owner's scope
ends. Moves are tracked and copies are explicit, so resources clean up like C++'s RAII, without
lifetimes to annotate.

**Errors you can see.** A function that can fail returns `E!T`, and the caller has to `try`,
`catch` or keep it. Optionals (`T?`) mark what may be missing. Nothing is thrown.

**Generic code that costs nothing.** Templates make one copy per set of arguments, with
specialization, packs and constant parameters. Code can run in the compiler (`comptime`), and types
are values there.

**Every other language is one step away.** Volt reads C headers and C++ headers (classes,
templates, the standard library) and ordinary Rust crates and Zig files (`use rust { "geom" } as
geom;`) directly, builds Go modules listed in `bolt.toml`, and calls Python, Java, .NET and Lua
through packages that embed them. The other way round, `voltc bindings` (or a `bindings` list in `bolt.toml`) makes a
Volt library usable from C, C++, Rust, Zig, Python, JavaScript and TypeScript, C#, Java, Go, Lua,
Dart, Swift, Kotlin and Ruby. See [Interop](/volt-bootstrap/interop/c/).

**One toolchain.** bolt builds packages and workspaces, fetches git dependencies, runs tests and
benches, and runs build files written in Volt. Diagnostics show the code they're about and suggest
fixes; a language server and a VS Code extension come with it.

**It compiles to C.** The C backend writes readable C, so Volt runs wherever a C compiler does. The
LLVM backend makes native code directly. The compiler is written in Volt and builds itself through
both.

## Next to the others

| | Memory | Errors | Generics | C interop | Runtime |
| --- | --- | --- | --- | --- | --- |
| **Volt** | owned, freed at scope end | `E!T` | templates, comptime | reads C, C++ headers | none |
| C | manual | return codes | macros | native | none |
| C++ | RAII | exceptions | templates | native | exceptions, RTTI |
| Rust | borrow checked | `Result` | traits | bindgen | unwinding |
| Zig | manual, allocators | error unions | comptime | `@cImport` | none |
| Go | garbage collected | extra returns | generics | cgo | GC, scheduler |

Volt sits between C++ and Zig: C++'s RAII and templates without exceptions, RTTI or implicit
copies, and Zig's error values and comptime.

## When to pick something else

- **You need proven memory safety.** Volt tracks ownership and moves but has no borrow checker,
  so a reference can outlive what it points to. Debug builds poison freed memory, which catches
  some of that, not all. Rust proves it at compile time.
- **You need a large package ecosystem.** bolt has path and git dependencies, but no registry.
- **You need a stable language today.** Volt is young: the language, std and tools still change,
  and there's no 1.0 yet.

## Where to go next

- [Install](/volt-bootstrap/start/install/) builds the compiler and bolt.
- [Hello, Volt](/volt-bootstrap/start/hello/) makes a package and runs it.
- [A tour of Volt](/volt-bootstrap/start/tour/) shows the whole language on one page.
