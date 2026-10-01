---
title: Rust and Zig
description: A bolt package that uses a Rust crate or a Zig file, and Cargo and Zig projects that use Volt.
sidebar:
  order: 3
---

Both meet Volt at the C ABI, and bolt and two small helpers do the plumbing both ways.

## Volt uses them

Name the crate or the file under `[foreign]` in `bolt.toml`:

```toml
[foreign]
geom = { rust = "../geom" }        # a Cargo crate's directory
fastmath = { zig = "fastmath.zig" }
```

bolt builds each one into a static library in `target/<profile>/foreign/`: a crate with
`cargo rustc --crate-type staticlib` (so any library crate works, with `--release` in an optimized
profile), a Zig file with `zig build-lib` (`ReleaseSafe` or `Debug`). It also writes `NAME.h`, the
library's C API read from its source. It links them, and the system libraries rustc says a Rust
library needs, into the package's programs. The code imports the header like any C header:

```rust
// ../geom/src/lib.rs
#[repr(C)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[no_mangle]
pub extern "C" fn geom_dist(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}
```

```zig
// fastmath.zig
pub const Range = extern struct { lo: i32, hi: i32 };

export fn fm_clamp(x: i32, r: Range) i32 {
    return @max(r.lo, @min(r.hi, x));
}
```

```volt ignore
use std::io;
use { "geom.h" } as geom;
use { "fastmath.h" } as fm;

fn main() -> void {
    val a: geom::Point = { x: 0.0, y: 0.0 };
    val b: geom::Point = { x: 3.0, y: 4.0 };
    val r: fm::Range = { lo: 0, hi: 10 };
    std::println("{}", geom::geom_dist(a, b)); // 5
    std::println("{}", fm::fm_clamp(42, r));   // 10
}
```

What goes into the header:

| | Rust | Zig |
| --- | --- | --- |
| functions | `#[no_mangle] pub extern "C" fn` (or `#[unsafe(no_mangle)]`) | `export fn` |
| structs | `#[repr(C)]` with named fields | `extern struct` |
| enums | `#[repr(C)]` or `#[repr(i32)]` and the like, without fields | `enum(T)` |
| numbers | `i8`…`u64`, `isize`, `usize`, `f32`, `f64`, `bool`, `c_int` and the other `c_` types | the same names |
| pointers | `*const T`, `*mut T`, `&T`, `&mut T`, `Option<&T>`, `NonNull<T>` | `*T`, `[*]T`, `[*c]T`, `?*T` |
| function pointers | `extern "C" fn(A) -> R`, in an `Option` for a nullable one | `*const fn (A) callconv(.c) R` |

An enum's values become constants named `Enum_Variant` (`Quadrant_First`). A function whose types
aren't in that table isn't declared, and the header says so in a comment.
bolt reads `$CARGO` and `$ZIG` for the tools, else `cargo` and `zig` on the PATH.

## They use Volt

A Cargo project builds a Volt package from its build script with `volt-build` (in
`interop/rust/volt-build` in the repository):

```toml
# Cargo.toml
[build-dependencies]
volt-build = { path = "../volt/interop/rust/volt-build" }
```

```rust
// build.rs
fn main() {
    volt_build::Package::new("mathlib", "volt/mathlib").build();
}
```

```rust
// src/main.rs
include!(concat!(env!("OUT_DIR"), "/mathlib.rs")); // pub mod mathlib, the Rust bindings

fn main() {
    println!("{}", mathlib::ml_add(2, 3));
}
```

`build` runs `voltc lib NAME --static` and `voltc bindings NAME --lang rust` into `OUT_DIR` and
tells Cargo what to link. A Zig project does the same with `interop/zig/volt.zig`:

```zig
// build.zig
const volt = @import("volt.zig");
// ...after making exe:
volt.addPackage(b, exe, "mathlib", "volt/mathlib");
```

```zig
// src/main.zig
const mathlib = @import("mathlib");
```

Both take voltc from `$VOLTC`, else the PATH, and std from `$VOLT_STD`, else voltc's own. The
bindings' types are in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt):
`Result` for errors, `String` and `&str` for text, a type that frees itself when dropped for an
export struct, and the same in Zig with error unions, slices and `deinit()`.
