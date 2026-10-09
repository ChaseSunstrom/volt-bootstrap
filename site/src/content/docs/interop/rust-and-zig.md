---
title: Rust, Zig and Go
description: Calling ordinary Rust crates, Zig files and Go packages by importing them like a header, and Cargo and Zig projects that use Volt.
sidebar:
  order: 3
---

## Volt calls Rust

Runnable examples: [Volt calls Rust](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/rust) and [Zig](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/zig), and
[Rust](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/rust), [Zig](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/zig) and [Go](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/go) calling Volt.

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
`bolt import`, which reads the crate's public API as rustdoc sees it, builds a small shim crate with
cargo, and gives voltc the Volt declarations. Being rustdoc's view, it has what macros make, the
side of each `#[cfg]` that holds for the build, what `pub use` re-exports, by its public path
(`pub use inner::helper as renamed;` is `renamed`; `pub use extra::*;` brings `extra`'s items in),
and each `const`'s value as rustc works it out. An item under `#[cfg(doc)]`, which only
documentation sees, is kept when the build has one of its name (rustc's expanded source of the
crate says), so a documented stand-in brings in the item it documents. rustdoc writes this as
JSON, which stable's rustdoc does with `RUSTC_BOOTSTRAP=1` (bolt sets it); with a toolchain whose
rustdoc can't, bolt reads the source instead, which sees none of those, and says so. It caches the
result and redoes it when the crate changes. It works the same with `voltc run main.volt` and in a
bolt package.

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
| `Result<T, E>` with `E` one of the crate's enums (directly or through an alias like `type Result<T> = ...`) | `E!T`: a Volt error set of `E`'s variants, each with its fields (numbers, `char` as `u32`, text as `std::string`; a variant holding anything else carries the error's text), matched like an enum; named `E_error` when `E` is a value elsewhere too |
| any other `Result<T, E>` | `rust_error!T`; the `Err`'s text (`Display`, else `Debug`) is in `rust_error::ERROR` |
| a struct whose fields are all `pub` numbers, `bool`s, `char`s, fieldless enums or such structs | a Volt struct with those fields, passed by value |
| any other struct, or an enum with data | an owned handle: deleting it drops the Rust value, `copy` clones it (when it's `Clone`); a method taking `self` (or `self: Box<Self>`, `Rc<Self>`, `Arc<Self>`) empties it, one taking `&Rc<Self>`, `&Arc<Self>`, `Pin<&mut Self>` or `Pin<&Self>` borrows it |
| a `&mut T`, or a `&T` of a type that isn't `Clone` (an `Option` of one too), as a result | a lent handle: a reference into Rust's value, which deleting doesn't free; giving it away (a by-value call) stops the program. A `Clone` type's `&T` is a clone |
| `&[T]`, `Vec<T>` of the crate's types, as a result | `std::vec<T>`: of lent handles from a slice, of owned ones from a `Vec`; plain structs and enums copied |
| `async fn f() -> T`, or a result of `impl Future<Output = T>` | a Volt `async fn f() -> T`: `await` it, or call it to run it to the end; each poll of Rust's future that finds it not done waits up to a millisecond for its waker, then suspends. A crate that depends on tokio has its futures polled in a tokio runtime |
| a fieldless enum | a Volt enum with the same values |
| `pub const` of a number, `bool` or `&str`, however it's computed | a `val` of its value |
| a generic `fn`, method or type (`largest<T: PartialOrd>`, `Stack<T>`) | a generic `fn` or `struct`: each instance the program uses (`geom::largest(xs)`, `geom::Stack<i32>::new()`) is built for it |
| a parameter of `impl Fn(A) -> R` (or `FnMut`, `FnOnce`), `F: Fn(A) -> R`, `&dyn Fn(A) -> R`, `&mut dyn FnMut(A)`, `Box<dyn Fn(A) -> R>` | a Volt fn value `fn(A) -> R`: lent for the call when Rust borrows it (`&dyn`), otherwise moved to Rust, which drops it when it's done with it |
| a result of `impl Fn(A) -> R`, `Box<dyn FnMut(A) -> R>`, `impl FnOnce() -> R` | a value called with `f.call(a)`; deleting it drops the closure |
| `pub trait T` | a Volt trait `T` (a method with a body in Rust is `@optional`); the crate's types implementing it attach it |
| a parameter of `&dyn T`, `&mut dyn T`, `&impl T`, `impl T`, `S: T`, `Box<dyn T>` | a value of any type attaching `T`, Volt's own or the crate's: lent for the call when Rust borrows it, otherwise moved to Rust, which drops it when it's done with it |
| a result of `Box<dyn T>` or `impl T` | a `dyn_T`, which attaches `T`; deleting it drops the Rust value |

A generic is built per instance: when a check calls `geom::largest` with `i32` and `f64`, voltc asks
bolt for those two, which it builds into the shim as `largest::<i32>` and `largest::<f64>`, and
checks the program again (only when the instances it needs change). rustc checks each instance's
bounds: types that don't meet them are an error at the call, with rustc's reason.

Closures and traits cross both ways. Their methods' and closures' types are numbers, `bool`,
`char`, and text: `&str` and `String` in as `str`, `String` out as `std::string`, and a trait
method's `&str` result as `str` (lent, as in Rust). A Rust type's own impl of a method with a body
(`Square`'s `describe`) runs on its `dyn_T` and on the type; a Volt type that writes an `@optional`
one has it called by Rust, while a value of the trait union passes with Rust's body for it (a union
can't say which of its members wrote one). Rust may hand a Volt value it was given to another
thread, as C code could: Volt has no `Send`.

```volt ignore
use std::io;
use std::string;
use { "geom" } as geom;

struct tri { b: f64; h: f64; }

// pub trait Shape { fn area(&self) -> f64; fn name(&self) -> String; }
attach geom::Shape -> tri {
    fn area(this) -> f64 { return this.b * this.h / 2.0; }
    fn name(this) -> std::string { return std::string::from("tri"); }
}

fn main() -> void {
    val t: tri = { b: 4.0, h: 3.0 };
    std::println("{}", geom::area_of(&t));              // pub fn area_of(s: &dyn Shape) -> f64
    val u = geom::unit_square();                        // -> Box<dyn Shape>: a geom::dyn_Shape
    std::println("{} {}", u.area(), u.name());
    val add2 = geom::adder(2);                          // -> impl Fn(i32) -> i32
    std::println("{}", geom::apply(|| (x: i32) -> i32 { return x * 10; }, add2.call(1)));
}
```

A trait with an associated type or const, generic parameters, or a supertrait beyond `Send`, `Sync`
and `Sized` is left out, listed in a comment of the generated declarations (`VOLT_SHOW_IMPORT=1
voltc check main.volt` prints them).

A panic through a function stops the program with Rust's message, as it would in Rust. Every
function and method also has a `try_` form (`geom::try_at(xs, 9)`, and a closure's `try_call`)
that returns the panic as `rust_error::PANIC` with its message instead, the way C++'s `try_` forms
return exceptions; a `Result` function's `try_` form gives its own errors or `PANIC`. A crate
built with `panic = "abort"` aborts instead, as Rust does. cargo builds the shim from the crate's
directory, so its `rust-toolchain.toml` and dependencies apply.

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

    val xs: i32[3] = { 4, 9, 2 };
    std::println("{}", fm::largest(xs[..]));                // 9: zig built largest(i32, ..)
    var st = try fm::Stack<u8>::init(2);                    // fn Stack(comptime T: type) type
    st.push(1);
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
| `std.mem.Allocator` parameter | none: the shim passes Volt's allocator (the program's `std::mem::default_allocator`, as a `std.mem.Allocator`), so what Zig allocates is Volt's memory (not the C library's `malloc`), and `--leak-check` counts it |
| `comptime T: type`, `x: anytype` (and `@TypeOf(x)`), `comptime n: usize` | a generic fn: `<T: type>`, `<T_x: type>`, `<n: usize>` |
| `pub fn Name(comptime T: type) type { return struct { ... }; }` | a generic struct, `Name<T>`, with its fields and methods |
| a struct whose fields are all numbers, `bool`s, enums or such structs | a Volt struct with those fields, passed by value |
| any other struct, or one with a `deinit` | an owned handle: deleting it calls `deinit` (with the allocator when it takes one) and frees it; `copy` copies it when it has no `deinit` |
| an `enum` | a Volt enum with the same values |
| `pub const` of a number, `bool` or string | a `val` |

Generic functions and types get an instance per one a program uses: a call to
`fm::largest(xs[..])`, `fm::times<3>(7)` or a use of `fm::Stack<u8>` has bolt add that instance and
zig build it, as with Rust's generics above. One zig rejects is an error at the call,
with zig's reason (`fm::biggerOf("a", "b")`: operator > not allowed for type '[]const u8'). bolt
reads `$ZIG` for the compiler, else `zig` on the PATH.

## Volt calls Go

A `.go` file imports its package (the files of its directory), and a directory with a `go.mod`
imports that module's package. Nothing in the Go code is written for Volt: no `//export`, no cgo.
bolt asks Go's own type checker what the package exports and writes a cgo shim for it:

```volt ignore
use std::io;
use { "geom.go" } as geom;       // package geom, from this file's directory
use { "../shapes" } as sh;       // a module's directory: its root package

fn main() -> !void {
    var b: geom::Point = { X: 3.0, Y: 4.0 };    // a plain struct, by value
    b.Scale(2.0);                                // func (p *Point) Scale(k float64)
    std::println("{} {}", b.Norm(), geom::Upper("quiet"));      // 10 QUIET
    std::println("{}", try geom::Parse("42"));                  // (int, error)

    val sides: f64[3] = { 3.0, 4.0, 5.0 };
    var s = geom::NewShape("tri", sides[..]);   // *Shape: a handle; Go keeps it while Volt holds it
    s.Add(1.0);
    std::println("{} {}", s.Perimeter(), sh::Area(2.0, 3.0));
}
```

| Go | Volt |
| --- | --- |
| an exported `func F(...)` | `fn F(...)`, the same name |
| an exported method, on `T` or `*T` | a method; one on `*T` can change a plain struct, and the change comes back |
| `int`, `uint` | `isize`, `usize` |
| `int8`…`uint64`, `float32`, `float64`, `bool`, `byte`, `rune` | the same sizes (`u8`, `i32`) |
| `string` | `str` in, `std::string` out |
| `[]T`, `[N]T` | `T[..]` in (Go sees Volt's numbers and changes them in place; the package's types are converted for the call, and Go's changes come back; an array's length is checked), `std::vec<T>` out |
| `...T` (variadic) | `T[..]` |
| `(T, error)`, `error` | `go_error!T`, `go_error!void`; the error's text is in `go_error::ERROR` |
| `(T, bool)` | `T?` |
| several results; with an `error` last | a tuple, its elements named as Go names them (`(lo: isize, hi: isize)`); `go_error!(A, B)` |
| a struct whose fields are all exported numbers, `bool`s, enums or such structs | a Volt struct with those fields, passed by value |
| any other struct | an owned handle (a cgo `Handle`): Go's collector keeps the value until Volt deletes it. `T::new()` is Go's zero value, `copy` copies it as Go's assignment does, an exported field `F` is `F()` and `set_F(v)`. A `*T` result is a handle to that same value, a `T` one to a copy |
| `*int` and other pointers to numbers | `isize&` in (Go's change comes back); out, a `ptr<isize>` handle with `get()` and `put(v)` |
| `type T int` with constants of type `T` | a Volt enum with the same values |
| any other named number or `bool` (`time.Duration` too) | a Volt struct `{ value: T }`; a named `string` is a handle with `value()` and `T::new(s)` |
| `complex64`, `complex128` | a Volt struct `{ re, im }` |
| `map[K]V` | a `map<K, V>` handle (`k::map<std::string, isize>::new()` makes one): `get(k)` (a `V?`), `put(k, v)`, `contains(k)`, `remove(k)`, `len()`, `keys()` |
| `map[K]struct{}` (a set) | a `set<K>` handle: `add(k)`, `contains(k)`, `remove(k)`, `len()`, `keys()` |
| `chan T`, `<-chan T`, `chan<- T` | one `chan<T>` handle whichever way it goes: `chan<T>::new(capacity)`, `send(v)`, `recv()` (a `T?`: null once it's closed and empty), `close()`, `len()`, `cap()`; a call taking a `<-chan T` takes it |
| a slice of other elements (`[][]int`: `slice<std::vec<isize>>`), a pointer to another type (`ptr<T>`), an array of other elements, a named slice, array, map, channel or pointer type, `any`, another package's struct | a handle: a slice's `get(i)`, `put(i, v)`, `push(v)`, `len()`, `items()`; a pointer's `get()`, `put(v)`; with a named type's own methods |
| `func(...) ...`, a named func type (`type Op = fn(...) -> ...;` in Volt too) | a Volt fn value in (Go keeps it until its collector is done with it, then deletes it); a value called with `f.call(...)` out. It takes and gives numbers, `bool`s, text, slices, the package's types and funcs, several results (a tuple), `(T, bool)` (`T?`) and an `error` last (`go_error!T`); a `*int` parameter is an `isize&` |
| an interface | a Volt trait: the Go types with its methods attach it, a Volt type attaching it passes where Go takes one, and Go's values of it are `dyn_I` handles (`t.as_I()` of a Go type, `dyn_I::new(v)` of a Volt value). A Volt type's methods have the fn values' types; a method taking an array takes a `T[..]`, one giving an array gives a `std::vec<T>` (its length is checked), and one giving a `*T` of a plain struct gives the struct (Go gets a pointer to a copy) |
| a generic `func` or type (`Max[T cmp.Ordered]`, `Stack[T]`) | a generic `fn` or `struct`: each instance a program uses is built for it, and go checks its constraints (one they reject is an error at the call, with go's reason). Maps, sets, channels, pointers, slices of slices and arrays of slices of its type parameters are `map<K, V>`, `set<K>`, `chan<T>`, `ptr<T>`, `slice<std::vec<T>>` and `array2<std::vec<T>>` (the length is in the name: `array3<...>` for `[3][]T`). A Volt list can be the type argument (`Len<std::vec<isize>>(lists.items())` where Go takes `[]T`): Go reads each list in place |
| an exported constant of any type | a `val` of its value |
| an exported variable `V` | `V()` and `set_V(v)` |
| `type A = B` | `type A = B;` |
| another package's type the API names (`time.Time`) | the same, in a namespace of its package's name (`geom::time::Time`), with its methods |

The newer forms in use (`kinds.go` is ordinary Go, as in the table):

```volt ignore
use std::io;
use { "kinds.go" } as k;

struct tri { b: f64; h: f64; }

// type Figure interface { Area() float64; Name() string }
attach k::Figure -> tri {
    fn Area(this) -> f64 { return this.b * this.h / 2.0; }
    fn Name(this) -> std::string { return std::string::from("tri"); }
}

fn main() -> k::go_error!void {
    val xs: isize[3] = { 3, 9, 4 };
    std::println("{}", k::Max(xs[..]));                         // func Max[T cmp.Ordered](xs ...T) T
    std::println("{}", k::Apply(|| (x: isize) -> isize { return x * 3; }, 5));   // f func(int) int
    val (lo, hi) = k::MinMax(xs[..]);                           // (lo, hi int)
    val words: str[3] = { "a", "b", "a" };
    var counts = k::Count(words[..]);                           // map[string]int
    std::println("{} {} {}", lo, hi, counts.get("a") ?? 0);
    val r = k::Range(3);                                        // <-chan int, filled by a goroutine
    while (true) {
        val x = r.recv() ?? break;
        std::println("{}", x);
    }
    std::println("{}", k::Tell({ b: 4.0, h: 3.0 } as tri));     // func Tell(f Figure) string
    // func Spread(f func(int) (int, string)) string: a closure giving several results
    std::println("{}", k::Spread(|| (n: isize) -> (isize, std::string) { return (n, std::string::from("ab")); }));
    val chunks = k::Chunk(xs[..], 2);                           // [][]T: a slice<std::vec<isize>>
    val bad = k::try_At(xs[..], 5);                             // a panic, as go_error::PANIC
}
```

A `main` package works too (its `main` isn't run). The program links every `use go` import into
one library, so it has one Go runtime, started when the program starts. A panic stops the program
with Go's message, as it does in Go; each function's `try_` form (and a Go func value's
`try_call`) returns it as `go_error::PANIC` instead. The shim recovers it, so it never unwinds
through C, and the same goes for a panic while a Volt closure's slice result is handed to Go (it
stops the program with Go's message). Errors cross as their text: an error a Volt function gives Go is a new Go error with that
text. Calls are safe from any Volt thread, and Go may call a Volt closure from any goroutine, as C
code could. bolt reads `$GO` for the go command, else `go` on the PATH; cgo needs a C compiler.

What Go's own rules keep out, listed in a comment of the generated declarations
(`VOLT_SHOW_IMPORT=1 voltc check main.volt` prints them): an unexported type, or an internal
package's, which no other package can name; an interface with unexported methods, which only its
own package's types can have (Go's values of it are still `dyn_I` handles); a constraint, which
only a type parameter can have; and an untyped constant no Go number holds (`1 << 100`).

## Go, and C APIs you write yourself

Libraries with a C API of their own, Go modules built as one (`//export`), and Rust crates or Zig
files that export one (`#[no_mangle] pub extern "C" fn`, `export fn`), can be named under
`[foreign]` in `bolt.toml`:

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

Both take voltc from `$VOLTC`, else the PATH, and std from `$VOLT_STD`, else voltc's own. Python
and Node projects get the same from pip and npm: see
[pip install and npm install](/volt-bootstrap/interop/other-languages/#pip-install-and-npm-install). The
bindings' types are in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt):
`Result` for errors, `String` and `&str` for text, a type that frees itself when dropped for an
export struct (with its methods), and the same in Zig with error unions, slices and `deinit()`.
Rust takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape), as C
and C++ do: a generic's instances (`biggest_i32`), owned values as parameters, a Volt trait as a
Rust trait to implement (or one Volt made, as a `Box<dyn T>`), any closure (`impl FnMut`) taking
and giving text and handles, and closures given back as `Box<dyn FnMut>`. So does Zig: a Volt
trait takes any Zig value with its methods (lent as a pointer or given), callbacks are a context
and a function, and closures come back as a struct with `call` and `deinit()`.
