---
title: Rust, Zig and Go
description: A bolt package that uses a Rust crate, a Zig file or a Go module, and Cargo and Zig projects that use Volt.
sidebar:
  order: 3
---

All three meet Volt at the C ABI, and bolt and two small helpers do the plumbing both ways.

## Volt uses them

Name the crate, the file or the module under `[foreign]` in `bolt.toml`:

```toml
[foreign]
geom = { rust = "../geom" }        # a Cargo crate's directory
fastmath = { zig = "fastmath.zig" }
gomath = { go = "../gomath" }      # a Go module's directory
```

bolt builds each one into a static library in `target/<profile>/foreign/`: a crate with
`cargo rustc --crate-type staticlib` (so any library crate works, with `--release` in an optimized
profile), a Zig file with `zig build-lib` (`ReleaseSafe` or `Debug`), a Go module with
`go build -buildmode=c-archive`. It also writes `NAME.h`, the library's C API: read from the source
for Rust and Zig, and the header cgo writes for Go ([below](#go)). It links them, and the system libraries rustc says a Rust
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
bolt reads `$CARGO`, `$ZIG` and `$GO` for the tools, else `cargo`, `zig` and `go` on the PATH.

### Go

A Go library is a `main` package whose API is its `//export` funcs; cgo writes their C declarations,
with `GoString` (a pointer and a length), `GoInt` and the other Go types, into the header:

```go
// ../gomath/gomath.go
package main

import "C"

import "strings"

//export gm_add
func gm_add(a, b C.int) C.int { return a + b }

//export gm_upper
func gm_upper(s *C.char) *C.char { return C.CString(strings.ToUpper(C.GoString(s))) }

func main() {}
```

```volt ignore
use std::io;
use { "gomath.h" } as go;

extern "C" fn free(p: void*) -> void;

fn main() -> void {
    std::println("{}", go::gm_add(2, 40));                         // 42
    val up = go::gm_upper(@cast<cstr>("volt\0".ptr)) ?? return;   // C.CString: the C heap's
    free(@cast<void*>(up));
}
```

The program links the Go runtime with it, which starts its threads when the program does. The other
way round, `voltc bindings --lang go` writes a cgo package for a Volt library, see
[They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt).

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
