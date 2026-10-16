// WebAssembly with no C: `voltc build --target wasm32-wasi` makes a module a WASI host runs (node,
// wasmtime), and `--target wasm32-none` one a web page loads, its console and exit given by the page
// (run.mjs does both under node). std's runtime is the bare-metal one: memory grows as the heap
// needs it.
use std::io;
use std::fmt;

fn main() -> i32 {
    var xs: std::vec<u32> = {};
    for (i) in 0..5 {
        xs.push(@cast<u32>(i * i));
    }
    var squares: std::map<u32, u32> = {};
    for (k) in 0..2000 {
        squares.put(@cast<u32>(k), @cast<u32>(k % 7));
    }
    var sum: u32 = 0;
    for (k) in 0..2000 {
        val v = squares.get(@cast<u32>(k));
        if (v == null) {
            return 2;
        }
        sum += *v;
    }
    // a megabyte at once: past the module's first memory, so it grows
    val big = std::format("{}", "x".repeat(1048576).len());
    std::println("hello from wasm: {} items, last {}", xs.len, xs[4]);
    std::println("{:.2} {} {} {}", 2.0 / 3.0, @sizeof(usize), sum, big);
    return 3;
}
// expect: hello from wasm: 5 items, last 16
// expect: 0.67 4 5995 1048576
// exit: 3
