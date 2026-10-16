---
title: WebAssembly
description: Building Volt into WebAssembly modules for web pages and WASI hosts, with no C compiler and no C library.
sidebar:
  order: 6
---

`--target wasm32-none` and `--target wasm32-wasi` build a program into a WebAssembly module. As on
[bare metal](/volt-bootstrap/voltc/bare-metal/), nothing in the build is C: voltc compiles the
program and std through LLVM and links the module with `wasm-ld`, which comes with LLVM's lld.

```sh
voltc build hello.volt --target wasm32-wasi -o hello.wasm   # for a WASI host
voltc build hello.volt --target wasm32-none -o hello.wasm   # for a web page
```

## The two targets

| `--target` | For | Imports |
| --- | --- | --- |
| `wasm32-wasi` | a WASI host: node, wasmtime, wasmer | `wasi_snapshot_preview1`'s `fd_write` and `proc_exit` |
| `wasm32-none` | a web page, or any host that gives the module a console | `env.volt_console_write(ptr, len)` and `env.volt_exit(code)` |

Both export `_start`, which runs the program's `main` and then exits with its result, and the
module's `memory`. `usize` is 32 bits, as a pointer is. std's runtime is the bare-metal one: printing
goes to the console, a panic prints its message there and exits with 101, and the heap starts where
`wasm-ld` puts `__heap_base` and grows the memory a 64 KiB page at a time when it needs more. A
program that defines `volt_console_write` or `volt_exit` itself (as an `export fn`) is given that
instead of the host's.

In both, `@cfg("os")` is `none` (std has no OS layer there yet), `@cfg("arch")` is `wasm32` and
`@cfg("target")` is the `--target` name, so a library can tell them apart.

## Running a module

Under node, WASI's module runs through `node:wasi`:

```js
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const wasi = new WASI({ version: "preview1", args: [], env: {}, returnOnExit: true });
const { instance } = await WebAssembly.instantiate(await readFile("hello.wasm"), {
    wasi_snapshot_preview1: wasi.wasiImport,
});
process.exitCode = wasi.start(instance);
```

A page gives a `wasm32-none` module its console and exit:

```js
let memory;
const text = new TextDecoder();
const env = {
    volt_console_write: (p, n) => console.log(text.decode(new Uint8Array(memory.buffer, p, n))),
    volt_exit: (code) => { throw new Error(`exited with ${code}`); },
};
const { instance } = await WebAssembly.instantiateStreaming(fetch("hello.wasm"), { env });
memory = instance.exports.memory;
instance.exports._start();
```

`examples/wasm/run.mjs` runs either kind under node. The test suite builds `examples/wasm/hello.volt`
for both targets, in debug and release builds, and runs it there.

## Not yet

- WASI's files, arguments, environment and clock: std's `fs`, `process` and `time` are bare metal's
  there, so `std::process::args()` is empty and opening a file fails.
- `f128` arithmetic: LLVM calls compiler-rt's quad routines for it, which the module doesn't have.
- Threads, and calling JavaScript functions other than the console and exit from Volt.
