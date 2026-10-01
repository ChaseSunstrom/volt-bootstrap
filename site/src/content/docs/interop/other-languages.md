---
title: Other languages
description: Calling Volt from C, C++, Rust, Zig and Python, and calling them from Volt.
sidebar:
  order: 3
---

Everything meets at the C ABI.

## Volt calls them

- **C**: import the header, see [C](/volt-bootstrap/interop/c/).
- **C++**: `use cpp`, see [C++](/volt-bootstrap/interop/cpp/).
- **Rust**: declare a `#[no_mangle] pub extern "C" fn` with `extern "C" fn` and link the Rust static
  or shared library with `--cc`.
- **Zig**: the same, with Zig's `export fn`.
- **Python**: embed it like any C library: `use { "Python.h" } as py;` with the flags from
  `python3-config --includes` and `--ldflags --embed` passed through `--cc`.

```volt ignore
extern "C" fn rust_checksum(data: u8*, len: usize) -> u32;   // from a Rust staticlib

fn main() -> void {
    val bytes = "volt";
    val sum = rust_checksum(@cast<u8*>(bytes.ptr), bytes.len);
}
```

## They call Volt

Mark the functions other languages call with `export fn`: a C calling convention and an unmangled
name. Then build a library and its declarations:

```sh
voltc lib mathlib --pkg mathlib=lib --shared -o libmathlib.so   # or --static: libmathlib.a
voltc bindings mathlib --pkg mathlib=lib --lang c      > mathlib.h
voltc bindings mathlib --pkg mathlib=lib --lang rust   > mathlib.rs
voltc bindings mathlib --pkg mathlib=lib --lang python > mathlib.py
```

A shared or static library built this way is self-contained: the package, what it uses from std,
and the runtime. A program that links the static one also links `-lm -lpthread`. The runtime has
threads, and before glibc 2.34 they're in libpthread; elsewhere the flag does no harm.

```volt
struct vec2 {
    x: f64;
    y: f64;
}

error math_error { DIVIDE_BY_ZERO }

export fn vec2_len2(v: vec2) -> f64 {
    return v.x * v.x + v.y * v.y;
}

export fn safe_div(a: i32, b: i32) -> math_error!i32 {
    if (b == 0) {
        return math_error::DIVIDE_BY_ZERO;
    }
    return a / b;
}
```

What can cross: integers and floats, `bool`, structs made of those, plain enums, error sets (as
their codes), `E!T` (a struct of the error code and the value), `str` (a pointer and a length),
pointers, and `extern "C"` function pointers. Anything else in an exported signature is an error
that names the function.

`--lang` is one of `c`, `cpp`, `rust`, `zig` or `python`. The Python bindings use `ctypes` and load
the shared library.

## In bolt

```toml
[lib]
kind = ["volt", "shared", "static"]   # the usual Volt library, plus libNAME.so and libNAME.a
bindings = ["c", "python"]            # mathlib.h and mathlib.py next to them
```

`bolt build` puts them in `target/<profile>/`. `tests/interop` in the repository has a client for
each language.
