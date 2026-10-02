---
title: Rust, Zig and Go
description: Calling ordinary Rust crates and Zig files by importing them like a header, Go libraries through bolt, and Cargo and Zig projects that use Volt.
sidebar:
  order: 3
---

## Volt calls Rust

One line imports a crate, as one imports a C header, and its public API is Volt functions and
types:

```volt ignore
use std::io;
use { "../geom" } as geom;          // the crate's directory (it has a Cargo.toml), from this file

fn main() -> !void {
    val d = geom::dist(geom::Point::new(0.0, 0.0), geom::Point::new(3.0, 4.0));
    std::println("{} {}", d, geom::greet("volt"));          // 5 hello, volt

    var s = geom::shapes::Shape::new("tri");                // a Rust value, owned by s
    s.add_side(3.0);
    std::println("{}", try s.side(0));                      // a Result: Err is an error
}
```

The crate is plain Rust: `pub fn`, `pub struct`, `impl` blocks, `String`, `Vec`, `Option`, `Result`.
Nothing in it is written for Volt, with no `extern "C"`, `#[no_mangle]` or `#[repr(C)]`. voltc runs
`bolt import`, which reads the crate's public API, builds a small shim crate with cargo, and gives
voltc the Volt declarations. It caches the result and redoes it when the crate changes. It works the
same with `voltc run main.volt` and in a bolt package.

The import names a directory with a `Cargo.toml`, or a single `.rs` file: `use { "stats.rs" } as
stats;` makes that file a crate of its own (the files its `mod x;` lines name sit next to it), for
code that has no Cargo project around it.

| Rust | Volt |
| --- | --- |
| `pub fn f(...)` | `fn f(...)`; `pub mod m` is `namespace m` |
| `impl T { pub fn m(&self) }` | `attach fn m(this: T&)`; without `self`, `T::f(...)` (so `T::new(...)`) |
| `i8`…`u64`, `isize`, `usize`, `f32`, `f64`, `bool` | the same; `char` is `u32` |
| `&str`, `String` | `str` in, `std::string` out (a copy) |
| `&[T]`, `&mut [T]`, `Vec<T>` | `T[..]` in, `std::vec<T>` out; `&[&str]`, `Vec<String>`: `str[..]`, `std::vec<std::string>` |
| `Option<T>` | `T?` |
| `Result<T, E>` | `rust_error!T`; the `Err`'s `to_string()` is in `rust_error::ERROR` |
| a struct whose fields are all `pub` numbers, `bool`s, `char`s, fieldless enums or such structs | a Volt struct with those fields, passed by value |
| any other struct, or an enum with data | an owned handle: deleting it drops the Rust value, `copy` clones it (when it's `Clone`); a method taking `self` empties it |
| a fieldless enum | a Volt enum with the same values |
| `pub const` of a number, `bool` or `&str` | a `val` |

Generic functions, trait objects, closures and references returned into Rust-owned data aren't
callable from Volt; they're left out, listed in a comment of the generated declarations
(`VOLT_SHOW_IMPORT=1 voltc check main.volt` prints them). A panic stops the program, as it does
in Rust. cargo builds the shim from the crate's directory, so its `rust-toolchain.toml` and
dependencies apply.

## Volt calls Zig

A `.zig` file is imported the same way, with `zig build-lib` building its shim:

```volt ignore
use std::io;
use { "fastmath.zig" } as fm;        // the file, from this one; what it imports comes along

fn main() -> !void {
    var p = fm::Point::init(3.0, 4.0);
    std::println("{} {}", p.norm(), fm::add(2, 40));        // 5 42
    std::println("{}", try fm::upper("quiet"));             // QUIET: Zig allocated it, Volt freed it

    var s = try fm::shapes::Shape::init("tri");             // owns memory: delete calls its deinit
    try s.addSide(3.0);
}
```

| Zig | Volt |
| --- | --- |
| `pub fn f(...)` | `fn f(...)` |
| a `pub fn` in a struct whose first parameter is the struct (`T`, `*T`, `*const T`) | a method; otherwise `T::f(...)` |
| `pub const x = struct { ... }` without fields, `pub const x = @import("x.zig")` | `namespace x` |
| integers, `f32`, `f64`, `bool`, `c_int` and the like | the same |
| `[]const u8` | `str` in, `std::string` out |
| `[]const T`, `[]T`, `[]const []const u8` | `T[..]`, `str[..]` in; `std::vec<T>` out |
| `?T` | `T?` |
| `E!T`, `!T` | `zig_error!T`; the error's name is in `zig_error::ERROR` |
| `std.mem.Allocator` parameter | none: the shim passes `std.heap.c_allocator`, and frees what such a function returns once Volt has copied it |
| a struct whose fields are all numbers, `bool`s, enums or such structs | a Volt struct with those fields, passed by value |
| any other struct, or one with a `deinit` | an owned handle: deleting it calls `deinit` (with the allocator when it takes one) and frees it; `copy` copies it when it has no `deinit` |
| an `enum` | a Volt enum with the same values |
| `pub const` of a number, `bool` or string | a `val` |

Functions with `comptime` or `anytype` parameters are left out, listed in a comment of the
generated declarations. bolt reads `$ZIG` for the compiler, else `zig` on the PATH.

## Go, and C APIs you write yourself

Go modules, and Rust crates or Zig files that export a C API (`#[no_mangle] pub extern "C" fn`,
`export fn`), can be named under `[foreign]` in `bolt.toml`:

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
