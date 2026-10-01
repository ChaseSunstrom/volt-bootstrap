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
voltc bindings mathlib --pkg mathlib=lib --lang cpp    > mathlib.hpp
voltc bindings mathlib --pkg mathlib=lib --lang rust   > mathlib.rs
voltc bindings mathlib --pkg mathlib=lib --lang zig    > mathlib.zig
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

These types cross as they are laid out in Volt, which is how C lays them out:
- integers and floats, `bool`, and pointers;
- structs made of those, and plain enums;
- error sets, as their codes, and `E!T`, as a struct of the error code and the value;
- `str`, as a pointer and a length;
- slices `T[..]`, as a pointer and a count, and optionals `T?`, as the value and a `has` flag;
- `extern "C"` function pointers.

Three more need converting at the edge. `voltc lib` adds that code when it builds the library:
- **Owned text.** An export fn can return a `std::string`, or any type with
  `@attributes([@export_text("method")])`. The caller gets the text and frees it when it's done.
- **Classes.** Other languages hold an `export struct` by a handle and never see its fields. An
  export fn that returns one by value makes one, and the caller owns it. Export fns named
  `NAME_method` that take it as `NAME&` first are its methods. voltc adds `NAME_free`.
- **Callbacks.** A closure parameter `fn(A) -> R` takes a function from the other language. In C,
  that's a function pointer that gets the caller's data first, and then the data itself.

```volt
use std::string;

export fn greet(name: str) -> std::string {
    var s = std::string::from("hello, ");
    s.append(name);
    return move s;
}

export struct counter {
    count: i64;
}

export fn counter_new() -> counter {
    return { count: 0 };
}

export fn counter_add(c: counter&, by: i64) -> i64 {
    c.count += by;
    return c.count;
}

export fn each(xs: i32[..], f: fn(i32) -> void) -> void {
    for (x) in xs {
        f(x);
    }
}
```

Each language gets these in its own style:

| | C | C++ | Rust | Python | Zig |
| --- | --- | --- | --- | --- | --- |
| errors | a struct of the code and the value | throws `error` | `Result<T, Error>` | raises a class per error set, all deriving from `Error` | `Error!T` |
| owned text | `volt_text`, freed with `volt_text_free` | `std::string` | `String` | `str` | `VoltText`, with `bytes()` and `deinit()` |
| slices, optionals | structs | from vectors and arrays; `std::optional` | `&mut [T]`, `Option` | lists, `None` | `[]T`, `?T` |
| an export struct | a pointer, and `NAME_free` | a class that frees itself | a type that frees itself when dropped | a class with `close()` and `with` | a type with `deinit()` |
| callbacks | a function and a `void *` | `std::function` | `&mut dyn FnMut` | any callable | a context and a function |

Every binding also has the plain C functions: in C++ they're in namespace `raw`, in Rust in module
`raw`, and in Zig in struct `raw`. `--lang` is one of `c`, `cpp`, `rust`, `zig` or `python`. The
Python bindings use `ctypes` and load the shared library.

## In bolt

```toml
[lib]
kind = ["volt", "shared", "static"]   # the usual Volt library, plus libNAME.so and libNAME.a
bindings = ["c", "python"]            # mathlib.h and mathlib.py next to them
```

`bolt build` puts them in `target/<profile>/`. `tests/interop` in the repository has a client for
each language.
