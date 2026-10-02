# Interop examples

Small programs, each runnable on its own with `sh run.sh`. The script holds the exact commands, and
`expected.txt` holds what it prints. `cargo test --test interop interop_examples` runs every one,
skipping those whose toolchain isn't installed. They're tested on Linux; elsewhere, point `VOLT_STD`
at Volt's `std` directory.

## Other languages call Volt

[`calls-volt/greet`](calls-volt/greet) is one small Volt library: numbers, owned text and a class.
Its `bolt.toml` asks for a shared library and bindings for every language, and each client calls
it the way that language's own libraries are called.

| Language | Example | How it reaches Volt |
| --- | --- | --- |
| C | [calls-volt/c](calls-volt/c) | `greet.h` |
| C++ | [calls-volt/cpp](calls-volt/cpp) | `greet.hpp`: `std::string`, a class that frees itself |
| Rust | [calls-volt/rust](calls-volt/rust) | `greet.rs`: `String`, a type dropped like any other |
| Zig | [calls-volt/zig](calls-volt/zig) | `greet.zig` |
| Go | [calls-volt/go](calls-volt/go) | a cgo package |
| Python | [calls-volt/python](calls-volt/python) | `greet.py` (ctypes), with type stubs |
| JavaScript | [calls-volt/javascript](calls-volt/javascript) | a Node-API addon (node or bun) |
| TypeScript | [calls-volt/typescript](calls-volt/typescript) | the same addon, typed by `greet.d.ts` |
| Lua | [calls-volt/lua](calls-volt/lua) | a C module |
| Ruby | [calls-volt/ruby](calls-volt/ruby) | a C extension |
| Java | [calls-volt/java](calls-volt/java) | the FFM API (JDK 22+) |
| Kotlin/Native | [calls-volt/kotlin](calls-volt/kotlin) | cinterop of `greet.h` |
| C# | [calls-volt/csharp](calls-volt/csharp) | P/Invoke |
| Dart | [calls-volt/dart](calls-volt/dart) | `dart:ffi` |
| Swift | [calls-volt/swift](calls-volt/swift) | the C header as module `Cgreet` |

## Volt calls other languages

A `use` line imports the other language's code like a header, and the file's extension says which
language it is.

| Language | Example | The import |
| --- | --- | --- |
| C | [volt-calls/c](volt-calls/c) | `use { "shapes.h" } as c;` |
| C++ | [volt-calls/cpp](volt-calls/cpp) | `use { "counter.hpp" } as cpp;`: classes, templates, destructors |
| Rust | [volt-calls/rust](volt-calls/rust) | `use { "stats.rs" } as stats;` (or a crate's directory) |
| Zig | [volt-calls/zig](volt-calls/zig) | `use { "stats.zig" } as stats;` |

Go, Python, JavaScript, Java and .NET are next, imported the same way: `use { "gomath/" }`, `use {
"stats.py" }`, `use { "stats.js" }`, `use { "Stats.java" }`, `use { "Stats.dll" }`. Until then, the
[interop docs](https://chasesunstrom.github.io/volt-bootstrap/interop/other-languages/) show the
packages that reach them.
