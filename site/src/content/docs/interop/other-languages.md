---
title: Other languages
description: Calling Volt from C, C++, Rust, Zig, Python, JavaScript, C#, Java, Go, Lua, Dart, Swift, Kotlin and Ruby, and calling them from Volt.
sidebar:
  order: 9
---

Everything meets at the C ABI.

Each language has a small runnable example in both directions in
[examples/interop](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop): a Volt library that every language calls, and Volt
importing C, C++, Rust, Zig and Swift code. Each one is a `run.sh` with its exact commands.

## Volt calls them

- **C**: import the header, see [C](/volt-bootstrap/interop/c/).
- **C++**: import the header, `use { "shapes.hpp" } as x;`, see [C++](/volt-bootstrap/interop/cpp/).
- **Java**: import the sources, jars or class directories, `use { "geo/Point.java" } as geo;`,
  `use { "lib.jar" } as lib;` or `use java { "classes" } as x;`, see
  [Java](/volt-bootstrap/interop/java/).
- **Rust**, **Zig** and **Go**: import the file or the crate, `use { "geom.rs" } as x;`,
  `use { "../geom" } as x;` (a directory with a `Cargo.toml`, or a `go.mod`),
  `use { "fastmath.zig" } as x;` or `use { "geom.go" } as x;`, and call its public API, see
  [Rust, Zig and Go](/volt-bootstrap/interop/rust-and-zig/). The extension says which language it
  is; `use cpp`, `use rust`, `use zig` or `use go { ... }` says it outright where it's ambiguous.
- **Swift**: import the files, `use { "shapes.swift" } as x;`, and call their functions, structs,
  classes and enums, see [Swift](/volt-bootstrap/interop/swift/).
- **Python**: import the module, `use { "geom.py" } as geom;` (or a package's directory), see
  [Python](/volt-bootstrap/interop/python/). Or embed it like any C library: `use { "Python.h" } as py;` with the flags from
  `python3-config --includes` and `--ldflags --embed` passed through `--cc`.
- **JavaScript** and **TypeScript**: import the module, `use { "geom.ts" } as geom;` (a `.js` one
  takes its types from the `.d.ts` beside it), see
  [JavaScript and Node.js](/volt-bootstrap/interop/node/). For Node.js, write the addon in Volt
  with `interop/node`, see [Node.js addons](/volt-bootstrap/interop/node/#addons-written-in-volt).
- **C#** and other .NET languages: import the sources or the assembly, `use { "Geo.cs" } as geo;`
  or `use { "Lib.dll" } as lib;`, see [.NET](/volt-bootstrap/interop/dotnet/).
- **Lua**: embed it with the `interop/lua` package, see [Lua](/volt-bootstrap/interop/lua/).

The other way, a program in any of these languages can embed Volt itself and run Volt source it
loads at run time, through `libvoltvm`: see [Embedding Volt](/volt-bootstrap/interop/embedding/).

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

Cargo and Zig projects can have their build do this, see
[They use Volt](/volt-bootstrap/interop/rust-and-zig/#they-use-volt).

A shared or static library built this way is self-contained: the package, what it uses from std,
and the runtime. A program that links the static one also links `-lm -lpthread`. The runtime has
threads, and before glibc 2.34 they're in libpthread; elsewhere the flag does no harm.

```volt
public struct vec2 {
    x: f64;
    y: f64;
}

public error math_error { DIVIDE_BY_ZERO }

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

More need converting at the edge. `voltc lib` adds that code when it builds the library:
- **Owned text.** An export fn can return a `std::string`, or any type with
  `@attributes([@export_text("method")])`. The caller gets the text and frees it when it's done.
- **Classes.** Other languages hold an `export struct` by a handle and never see its fields, and so
  is any struct C can't hold by value: one that owns something (it has a `delete`, or a field
  does, like a `std::string`) or has a field without a C form. An export fn that returns one by
  value makes one, and the caller owns it. Its methods are the `export attach fn`s on it, and
  export fns named `NAME_method` that take it as `NAME&` first. voltc adds `NAME_free`, which runs
  its `delete`.
- **Callbacks.** A closure parameter `fn(A) -> R` takes a function from the other language. In C,
  that's a function pointer that gets the caller's data first, and then the data itself.

```volt
use std::string;

export fn greet(name: str) -> std::string {
    var s = std::string::from("hello, ");
    s.append(name);
    return s;
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

| | errors | owned text | slices, optionals | an export struct | callbacks |
| --- | --- | --- | --- | --- | --- |
| C | a struct of the code and the value | `volt_text`, freed with `volt_text_free` | structs | a pointer, and `NAME_free` | a function and a `void *` |
| C++ | throws `error` | `std::string` | from vectors and arrays; `std::optional` | a class that frees itself | `std::function` |
| Rust | `Result<T, Error>` | `String` | `&mut [T]`, `Option` | a type that frees itself when dropped | `&mut dyn FnMut` |
| Python | raises a class per error set, all deriving from `Error` | `str` | lists, `None` | a class with `close()` and `with` | any callable |
| Zig | `Error!T` | `VoltText`, with `bytes()` and `deinit()` | `[]T`, `?T` | a type with `deinit()` | a context and a function |
| JavaScript | throws an `Error` whose `code` is the name | a string | arrays (written back), `null` | a class with `close()` and `Symbol.dispose` | any function (one throws `voltError(name)` to give Volt an error) |
| C# | throws a `VoltException` subclass per error set | `string` | `Span<T>` (text and handles from any `IEnumerable`), `T?` | an `IDisposable` class over a `SafeHandle` | `Action` or `Func` |
| Java | throws a `VoltException` subclass per error set | `String` | arrays, `null` | an `AutoCloseable` class, freed by a `Cleaner` if not closed | a functional interface |
| Go | `(T, error)`, with an `*Error` value per code for `errors.Is` | `string` | slices; `*T` in, `(T, bool)` out (a handle: `nil` for none) | a type with `Close`, and a finalizer | a `func` |
| Lua | raises a table with its `name` and `code` (a callback gives `nil, err`) | a string | sequences (written back), `nil` | a userdata with `close()`, `<close>` and `__gc` | any function |
| Dart | throws a `VoltError` subclass per error set | `String` | `List`s (plain values written back), `T?` | a `VoltObject` with `close()`, and a `NativeFinalizer` | any function |
| Swift | throws its error set's enum | `String` | `inout` arrays (written back), `[String]`, `T?` | a class with `close()`, freed by `deinit` | a closure |
| Kotlin/Native | throws a `VoltException` subclass per error set | `String` | primitive arrays (in place) or `List`s, `T?` | an `AutoCloseable` class, freed by a `Cleaner` if not closed | any function (one throws `VoltException.of(code)` to give Volt an error) |
| Ruby | raises a `Mod::Error` subclass per error set | a `String` | `Array`s (written back), `nil` | a class with `close`, freed by the GC | a block, or anything with `call` |

A generic export fn exports the instances it names, one `@instance` per instance with a type per
generic parameter. Each is a function of its own, named after its arguments:

```volt
<T: type>
@attributes([@instance(i32), @instance(f64)])
export fn biggest(xs: T[..]) -> T {
    var best = xs[0];
    for (x) in xs {
        if (x > best) {
            best = x;
        }
    }
    return best;
}
```

C and Rust call `biggest_i32` and `biggest_f64`; C++ calls `biggest`, an overload per instance
(each keeps its C name when two take the same parameters).

### Every shape

Every language's bindings take more than the plain shapes; Go's forms are under [Go](#go),
Kotlin/Native's under [Kotlin/Native](#kotlinnative), Dart's under [Dart](#every-shape-in-dart),
Python's on
[its page](/volt-bootstrap/interop/python/#python-calls-volt), Java's on
[its page](/volt-bootstrap/interop/java/#java-calls-volt), C#'s on
[its page](/volt-bootstrap/interop/dotnet/#every-shape), JavaScript's on
[Node.js's](/volt-bootstrap/interop/node/#every-shape), Lua's on
[its page](/volt-bootstrap/interop/lua/#every-shape), Ruby's [below](#every-shape-in-ruby), Swift's on
[its page](/volt-bootstrap/interop/swift/#every-shape):

- **Owned values as parameters.** Text (`std::string`) comes in as a `str` that Volt copies (a
  `&str` in Rust, a `[]const u8` in Zig); a handle by value is given to the fn, which deletes it
  (C++'s class gives it up, Rust's type is moved in, Zig's and Python's are given up).
- **Traits.** A fn taking a trait (`s: shape&`, lent, or `s: shape`, which the fn takes over) takes
  any object the other language has: in C a `shapelib_shape`, a table of the trait's functions
  (each taking the object first), the object, and what frees it (null when lent). In C++ the trait
  is an abstract class to subclass, passed as `shape &` or `std::unique_ptr<shape>`; in Rust it's
  a trait to implement, passed as `&mut dyn shape` or `Box<dyn shape>`; in Zig it's any value with
  the trait's methods, lent as a pointer or given by value (its `deinit` runs when Volt is done);
  in Python it's a class to subclass (its fns abstract), and any object with the fns passes, lent or
  given (kept until Volt drops it). A Volt value of the trait comes back the same way: C calls its
  table and its `drop`, C++ gets a `std::unique_ptr<shape>`, Rust a `Box<dyn shape>` (a
  `volt_shape`, which frees it when dropped), Zig a `volt_shape` with the methods and `deinit()`,
  Python a `shape` whose fns call Volt's (freed by `close()`, a `with` block or the garbage
  collector).
- **Closures taking and giving text and handles**, in callbacks and in traits' functions: text in
  is a `str` (a `std::string` in C++, a `String` in Rust), text back is owned (`volt_text`; a
  `std::string` in C++, a `String` in Rust, `[]const u8` in Zig), a handle is the class (Rust's
  and Zig's type), and one Volt lends is a class that never frees it (in Rust a `&T`). Rust takes
  any closure (`impl FnMut`), Zig a context and a function, Python any callable, and an `E!T`
  callback gives back a `Result<T, Error>` (Zig's `Error!T`; in Python it returns the value or
  raises the error set's class). Python's `ctypes` can't make a C function that gives a struct
  (text, `E!T`), so the library has a relay for each callback and trait fn that does, which takes
  the result from Python through a pointer.
- **Lists, and text and handles in slices and optionals.** An export fn can return a
  `std::vec<T>`: in C the caller gets its elements, how many, and what frees them
  (`volt_list_free`); text in it is lent as a `str` until then, and each handle in it is the
  caller's. As a parameter, a `std::vec<T>` takes a slice of those, which Volt copies (handles in
  it are given up). A `std::string[..]` or a slice of an export struct takes a slice of `str`s or
  of handles (each once), made into Volt's for the call (a handle's value is with the call until it
  returns, so a callback reaching it through the handle sees it as it was). A `std::string?` comes back as an
  optional owned text and goes in as a `str?`; an optional handle is its pointer, null for none.
  A `std::vec<T>` comes back as a `std::vector` in C++ (of `std::string`s, or of the classes), a
  `Vec` in Rust, a `VoltList(T)` with `items()` and `deinit()` in Zig, and a `list` in Python.
  Containers of text and handles go in from a `std::vector`, from `&[impl AsRef<str>]` and
  `&mut [T]` (or a `Vec<T>` given) in Rust, from `[]const []const u8` and `[]const T` in Zig, and
  from any sequence in Python. Optional text and handles are `std::optional`, `Option`, `?T` and
  `None` or the value.
- **Slices of slices.** A `T[..][..]` (of numbers or structs) takes an array of arrays: `long[][]`
  in Java and C#, `[[T]]` in Swift, `[][]T` in Go, a `List` of arrays (`LongArray`) in Kotlin, a
  list of lists in Python, Dart, JavaScript and Ruby, a table of tables in Lua, and a slice of slices in C, C++, Rust and Zig; what
  Volt writes into the elements comes back.
- **Arrays by value.** An export fn taking or giving a `T[N]` (numbers, bools, enums, or structs of
  those) passes it whole, as C passes a struct wrapping it: `PKG_array_T_N` (its elements in `v`)
  in C, `std::array<T, N>` in C++, `[T; N]` in Rust, `[N]T` in Zig and Go, a list in Python and
  Dart, `long[]` (and the like) in Java and C#, an array in JavaScript, Ruby and Swift, a
  `LongArray` (and the like) in Kotlin and a table in Lua. One of the wrong length is refused.
  Callbacks, trait fns and `extern "C"` fn types don't take arrays by value yet.
- **Any name.** A parameter named like a word the language keeps (`from` in Python, `type` in
  Zig, `self` in Rust, `typeof` in C), like one of the package's types, or like a name the wrapper
  uses itself gets a `_` after it in that language (`from_`), so it still gets its own value. A
  struct field does too (`t.from_` in Python, `t.int_` in C, `t.self_` in Rust; Zig keeps it as
  `t.@"type"`, C# as `t.@int`), and so does an export fn's wrapper (`from_()` in Python). An export
  fn C or C++ can't declare (`int`, `typeof`, `delete`) is exported as `int_`.
- **Closures given back.** A fn returning `fn(A) -> R` gives a struct of the function, its data and
  what frees it; in C++ a `std::function`, which frees it with its last copy; in Rust a
  `Box<dyn FnMut(A) -> R>`, which frees it when dropped; in Zig a struct with `call` and
  `deinit()`; in Python a callable, freed by `close()`, a `with` block or the garbage collector. (A
  Volt fn value borrows its closure, so what comes back is a function or one a longer-lived value
  holds.)

```volt
use std::string;

public trait shape {
    fn area(this) -> f64;
    fn name(this) -> std::string;
}

public struct square {
    side: f64;
}

attach shape -> square {
    fn area(this) -> f64 {
        return this.side * this.side;
    }
    fn name(this) -> std::string {
        return std::string::from("square");
    }
}

export fn describe(s: shape&) -> std::string {
    var out = s.name();
    out.append(" of area ");
    out.append_int(@cast<i64>(s.area()));
    return out;
}
```

```cpp
struct circle : shapelib::shape {
    double r = 1;
    double area() override { return 3 * r * r; }
    std::string name() override { return "circle"; }
};

circle c;
std::printf("%s\n", shapelib::describe(c).c_str()); // circle of area 3
```

```rust
struct Circle {
    r: f64,
}

impl shapelib::shape for Circle {
    fn area(&mut self) -> f64 { 3.0 * self.r * self.r }
    fn name(&mut self) -> String { "circle".to_string() }
}

let mut c = Circle { r: 1.0 };
println!("{}", shapelib::describe(&mut c)); // circle of area 3
```

```zig
const Circle = struct {
    r: f64,
    pub fn area(self: *Circle) f64 {
        return 3 * self.r * self.r;
    }
    pub fn name(self: *Circle) []const u8 {
        _ = self;
        return "circle";
    }
};

var c = Circle{ .r = 1 };
const d = shapelib.describe(&c);
defer d.deinit();
std.debug.print("{s}\n", .{d.bytes()}); // circle of area 3
```

```python
class Circle(shapelib.shape):
    def __init__(self, r):
        self.r = r

    def area(self):
        return 3 * self.r * self.r

    def name(self):
        return "circle"


print(shapelib.describe(Circle(1)))  # circle of area 3
```

An override that throws (or panics, in Rust) ends the program: Volt code doesn't unwind C++
exceptions or Rust panics (Rust 1.81 and later abort when a panic reaches an `extern "C"`
function). In Python, an exception a callback or a trait's fn raises (other than an `E!T`'s
error) comes out of the call that led to it once Volt returns: Volt gets a stand-in meanwhile (an
error of the set for `E!T`, empty text, zero), and a function that has to give an object (a handle)
ends the program instead, printing the exception, as a Volt panic does. A `str` a Python callback
gives back is kept for the program's life (once per value), as Rust's `&'static str` is; give
`std::string` for text made per call.

Python, JavaScript and TypeScript, C#, Java and Lua have pages of their own, each with both
directions: [Python](/volt-bootstrap/interop/python/#python-calls-volt),
[Node.js](/volt-bootstrap/interop/node/#javascript-calls-volt),
[.NET](/volt-bootstrap/interop/dotnet/#c-calls-volt), [Java](/volt-bootstrap/interop/java/#java-calls-volt)
and [Lua](/volt-bootstrap/interop/lua/#lua-calls-volt). C, C++, Rust and Zig are in
[Rust, Zig and Go](/volt-bootstrap/interop/rust-and-zig/#they-use-volt). The rest are here.

### Dart

`--lang dart` writes a Dart library over `dart:ffi` (Dart 3.4 or later; no packages). It loads
`libNAME.so` (or the library `$VOLT_NAME_LIB` names, with the package's name in capitals):

```dart
import 'mathlib.dart';

print(ml_greet('volt'));                      // hello, volt
final v = vec2.of(x: 1, y: 2);
ml_scale(v, 2);                               // v is now (2, 4)
try {
  ml_sqrt(-1);
} on math_error catch (e) {
  print(e.code == math_error.NEGATIVE);       // true
}
final c = counter('clicks');
c.add(2);
c.close();                                    // or leave it to its NativeFinalizer
```

Structs are `dart:ffi` structs, with `of` to make one and `copyFrom`; slices are `List`s, and what
Volt writes into one comes back. Enums are Dart enums, error sets are `VoltError` subclasses with
their codes as constants, and callbacks are functions: an exception one throws comes out of the
Volt call. The plain C functions are in class `Native`.

### Every shape in Dart

Dart takes [every shape](#every-shape) C does. What Volt gives out (an export struct, a closure, a
trait's value) is a `VoltObject`: `close()` frees it now, or its `NativeFinalizer` once it's
collected, and it can't be closed or given while a call it's lent to runs.

- **Owned values as parameters.** Text (`std::string`) is a `String`, which Volt copies. A handle
  by value is given to the fn, which deletes it: the object lets its handle go. What a call gives
  is checked first (open, not lent, given once), and given only once every argument converts.
- **Traits.** A Volt trait is an `abstract interface class` to implement. A fn taking `s: shape&`
  lends Volt the object for the call; one taking `s: shape` gives it, and Volt calls `close()` on
  it once it's done when it's also a `VoltCloseable`. A Volt value of the trait comes back as a
  `volt_shape`, which implements the interface.
- **Callbacks taking and giving text, handles and errors.** Text is a `String` both ways, a handle
  is its class (one Volt lends is closed once the callback returns), and an `E!T` callback returns
  its `T` or throws: `VoltError.of(code)` makes the error for one of the set's codes. Any other
  exception comes out of the call that led there once Volt returns: Volt gets a stand-in meanwhile
  (the set's first error for `E!T`, empty text, zero), and a callback that has to give a handle
  ends the program instead (exit 101), as a Volt panic does. A `str` one gives back is kept for the
  program's life (once per value); give `std::string` for text made per call.
- **Lists, and text and handles in slices and optionals.** A `std::vec<T>` comes back as a
  `List<T>` (of `String`s, or of the classes, each the caller's), and goes in from one (its
  handles given). A slice of text or of an export struct takes a `List` (lent for the call), an
  optional text or handle is a `String?` or a nullable class, and an optional in a slice is a `T?`.
- **Closures given back.** A fn returning `fn(A) -> R` gives a `closureN`, called like a function.

```dart
class Circle implements shape, VoltCloseable {
  double r = 1;
  @override
  double area() => 3 * r * r;
  @override
  String name() => 'circle';
  @override
  void grow(double by) => r += by;
  @override
  void close() => print('circle gone');
}

print(describe(Circle()));                  // circle of area 3, lent
print(grow_twice(Circle()));                // circle gone, then 27.0: given
print(shout((s) => '$s!', 'hey'));          // hey!
final hi = greeter();
print(hi('volt'));                          // hello, volt
hi.close();
final ann = account.open('ann');
print(owners([ann]));                       // [ann]: a List<String>
```

A Dart function Volt calls runs on the thread that called Volt (its `NativeCallable` is
isolate-local): one Volt keeps and calls later from another thread, or from a `NativeFinalizer`
(a handle holding a Dart object Volt was given, collected without `close()`), can't reach Dart.

### Swift

`--lang swift` writes Swift over the C header, which Swift imports as module `C<package>`: put
`--lang c`'s header in a directory with a `module.modulemap`, and point `swiftc` at it.

```sh
mkdir Cmathlib
voltc bindings mathlib --pkg mathlib=lib --lang c > Cmathlib/mathlib.h
printf 'module Cmathlib {\n    header "mathlib.h"\n    export *\n}\n' > Cmathlib/module.modulemap
voltc bindings mathlib --pkg mathlib=lib --lang swift > mathlib.swift
swiftc -I Cmathlib mathlib.swift main.swift -L. -lmathlib
```

```swift
print(ml_greet("volt"))                       // hello, volt
var v = vec2(x: 1, y: 2)
ml_scale(&v, 2)                               // v is now (2, 4)
do {
    _ = try ml_sqrt(-1)
} catch math_error.NEGATIVE {
    print("negative")
}
let c = counter("clicks")
_ = c.add(2)
c.close()                                     // or leave it to deinit
```

Structs are the C structs; slices are `inout` arrays, so what Volt writes comes back. Enums and
error sets are Swift enums (an error set's raw values are its codes); a function that can fail
`throws`. Callbacks are closures. Swift takes [every shape](#every-shape): a trait is a protocol,
a closure given back is a class called like a function, and lists are arrays (see
[Swift](/volt-bootstrap/interop/swift/#every-shape)).

### Kotlin/Native

`--lang kotlin` writes Kotlin over `cinterop`'s view of the C header, in package `c<package>`:

```sh
voltc bindings mathlib --pkg mathlib=lib --lang c > mathlib.h
printf 'headers = mathlib.h\npackage = cmathlib\n' > mathlib.def
voltc bindings mathlib --pkg mathlib=lib --lang kotlin > mathlib.kt
cinterop -def mathlib.def -compiler-option -I. -o mathlib_c
kotlinc-native mathlib.kt main.kt -l mathlib_c.klib -linker-options "-L. -lmathlib" -o main
```

On Linux, Kotlin/Native links against its own, older glibc; a library built against a newer one
needs `--allow-shlib-undefined` in the linker options too.

```kotlin
println(ml_greet("volt"))                     // hello, volt
val v = vec2(1.0, 2.0)
ml_scale(v, 2.0)                              // v is now vec2(x=2.0, y=4.0)
try {
    ml_sqrt(-1.0)
} catch (e: math_error) {
    println(e.code == math_error.NEGATIVE)    // true
}
counter("clicks").use { it.add(2) }           // freed by use, close or a Cleaner
```

Structs are data classes, copied in and out (and back, when Volt takes one by reference). A slice
of numbers is a primitive array (`IntArray`, `DoubleArray`, ...), which Volt reads and writes in
place; a slice of anything else (structs, enums, text) is a `List`. Enums are enum classes, error
sets `VoltException` subclasses, and callbacks are any function: an exception one throws comes out
of the Volt call. An `E!T` passed as a value (a parameter, a callback's argument, a field) is a
`Result<T>`. A method named like Kotlin's own (`close`, `toString`, `hashCode`, `equals`) gets a
`_`: an export struct's `close` is `close_()`, since `close()` frees it.

Kotlin/Native takes [every shape](#every-shape). Owned text goes in as a `String` (Volt copies it),
and a handle by value as its class, which gives the handle up. A trait is an interface: any Kotlin
object implementing it passes where Volt takes one, lent for the call or given (kept until Volt is
done with it, then closed if it's `AutoCloseable`), and one Volt gives back is a `volt_T` with the
methods and `close()`. A callback takes and gives `String`s and handles (one Volt lends is a view,
closed once the callback returns), and one giving `E!T` throws `VoltException.of(code)` for an
error; a closure given back is a `ClosureN`, a function you can call (and pass as a callback) with
`close()`. A `std::vec<T>` comes back as a `List` and goes in from one (handles in it are given
up), slices of text and handles go in from `List<String>` and `List<T>`, and optional text and
handles are `T?`. A call converts all its arguments and checks what it gives up (open, its own, not
in use by a running call, once) before anything is given; a running call's handles can't be closed
or given meanwhile. An exception in Kotlin code Volt calls doesn't unwind through Volt: Volt gets
a stand-in, and the call throws it once it's back (when the code had to give Volt a handle, there's
none to give, and the program ends).

```kotlin
class Circle(var r: Double) : shapelib.shape {
    override fun area() = 3 * r * r
    override fun name() = "circle"
    override fun grow(by: Double) { r += by }
}

println(describe(Circle(1.0)))                // circle of area 3
make_square(2.0).use { sq ->                  // a volt_shape
    doubler().use { d -> println("${sq.area()} ${d(21)}") } // 4.0 42
}
account.open("ann").use { println(owners(listOf(it))) } // [ann]
```

### Ruby

`--lang ruby` writes a C extension. Build it against the library and Ruby's headers, then
`require` it:

```sh
voltc bindings mathlib --pkg mathlib=lib --lang ruby > mathlib_ruby.c
cc -shared -fPIC -I"$(ruby -e 'print RbConfig::CONFIG["rubyhdrdir"]')" \
   -I"$(ruby -e 'print RbConfig::CONFIG["rubyarchhdrdir"]')" mathlib_ruby.c -L. -lmathlib -o mathlib.so
```

```ruby
require "mathlib"
puts Mathlib.ml_greet("volt")                 # hello, volt
v = Mathlib::Vec2.new(1.0, 2.0)
Mathlib.ml_scale(v, 2.0)                      # v is now (2.0, 4.0)
begin
  Mathlib.ml_sqrt(-1.0)
rescue Mathlib::MathError => e
  puts e.code == Mathlib::MathError::NEGATIVE # true
end
c = Mathlib::Counter.new("clicks")
c.add(2)
c.close                                       # or leave it to the GC
```

The package is a module (its name capitalized), structs are `Struct` classes (a `Hash` with the
fields works too; text in one is a `String`, an array an `Array` of exactly its length, a pointer a
`Pointer` from another call or `nil`), enums are modules of constants, and error sets are
`Mathlib::Error` subclasses holding their codes (`Mathlib::MathError.new(Mathlib::MathError::NEGATIVE)`
makes one, and an `E!T` parameter takes it or the value). A number by reference (`n: i32*`,
`x: f64&`) is an `Array` of one, `[7]`, and what Volt writes comes back into it. A callback
is a block or a `Proc` (anything with `call`); an exception it raises comes out of the Volt call.
Integers that don't fit the parameter, and wrong types, raise.

### Every shape in Ruby

Ruby takes [every shape](#every-shape) C does:

- **Owned values as parameters.** Text (`std::string`) is a `String`, which Volt copies. A handle
  by value is given to the fn: the object lets its handle go (it's closed after), and Volt deletes
  it.
- **Traits.** Any object with the trait's methods passes: `s: shape&` lends it for the call, and
  `s: shape` gives it, kept from the GC until Volt drops it and calls its `close` (when it has one,
  and unless Volt drops it while the GC runs, as at exit). A Volt value of the trait comes back as
  a `Mod::Shape`, whose methods call Volt's, freed by `close` or the GC.
- **Callbacks taking and giving text, handles and errors.** Text is a `String` both ways, a handle
  is its class (one Volt lends is closed once the callback returns), and an `E!T` callback returns
  its `T` or raises one of the error set's errors. A `str` (not owned text) a callback gives back
  is kept for good, one copy per value, since nothing frees it.
- **Lists, and text and handles in slices and optionals.** A `std::vec<T>` comes back as an `Array`
  (of `String`s, or of objects, each the caller's), and goes in as one, as does a slice of text or
  of an export struct (lent for the call; a list's handles are given). `nil` is an optional's none,
  in a slice too.
- **Closures given back.** A fn returning `fn(A) -> R` gives a `Mod::Fn`: `call` it (or `.()` it,
  or pass it as a block with `&`), and `close` frees it (or the GC does).

With a library like the one in [Every shape](#every-shape) (a `shape` trait, `describe(s: shape&)`,
`grow_twice(s: shape)`, `shout`, `greeter` and `owners`):

```ruby
class Circle
  def initialize(r) = @r = r
  def area = 3 * @r * @r
  def name = "circle"
  def grow(by) = @r += by
  def close = puts("circle gone")
end

puts Shapelib.describe(Circle.new(1))                # circle of area 3, lent
puts Shapelib.grow_twice(Circle.new(1))              # circle gone, then 27.0: given
puts Shapelib.shout(->(s) { s + "!" }, "hey")        # hey!
hi = Shapelib.greeter
puts hi.("volt")                                     # hello, volt
hi.close
ann = Shapelib::Account.open("ann")
p Shapelib.owners([ann])                             # ["ann"]
```

What a callback or a trait's method raises doesn't unwind through Volt: it's kept, Volt gets an
empty value (or, for `E!T`, an error), and the call that led there raises it once it returns; a
block's `break` works the same way. One that has to give Volt a handle has nothing to give
instead, so the program ends, as a Volt panic does. Volt can't take a handle that's closed, lent
to a callback, given twice, or in use by a running call (a callback can't close or give away what
the call it's in uses), nor one closed while the call's other arguments were converted: those raise
before anything is given.

### Go

`--lang go` writes a cgo package. Put it in a directory of your module, and point the C linker at
the library with `CGO_LDFLAGS=-L<dir>`. Names become exported Go names: `ml_greet` is `MlGreet`,
`vec2` is `Vec2`, `color::GREEN` is `ColorGreen`, and an export struct `counter` gets `NewCounter`
and methods.

```go
fmt.Println(mathlib.MlGreet("volt"))          // hello, volt
c := mathlib.NewCounter("clicks")
defer c.Close()
if _, err := mathlib.MlSqrt(-1); errors.Is(err, mathlib.MathErrorNegative) {
    fmt.Println(err)                          // NEGATIVE
}
```

Go takes [every shape](#every-shape). Owned text goes in as a `string` (Volt copies it), and a
handle by value as its type, which gives the handle up. A trait is an interface: any Go value with
its methods passes where Volt takes one, lent for the call or given (Volt calls its `Close`, if it
has one, when it's done with it), and one Volt gives back is a `*VoltT` with the methods and
`Close`. A callback is a `func` taking and giving `string`s, handles (one Volt lends never frees
it) and `(T, error)`; a closure given back is a `*ClosureN` with `Call` and `Close`. A
`std::vec<T>` comes back as a `[]T` and goes in from one (handles in it are given up), slices of
text and handles go in from `[]string` and `[]*T`, an optional text is a `*string` in and
`(string, bool)` out, and an optional handle is `nil` for none. A panic in a Go function Volt
calls doesn't unwind through Volt: it comes out of the call the function was passed to (when the
function had to give Volt a handle, there's none to give, and the program ends).

```go
type circle struct{ r float64 }

func (c *circle) Area() float64 { return 3 * c.r * c.r }
func (c *circle) Name() string  { return "circle" }

fmt.Println(shapelib.Describe(&circle{r: 1})) // circle of area 3
sq := shapelib.MakeSquare(2)                  // a *VoltShape
defer sq.Close()
d := shapelib.Doubler()                       // a *Closure1
defer d.Close()
fmt.Println(sq.Area(), d.Call(21))            // 4 42
```

A library that returns owned text also exports `NAME_text_free`, which frees it the way
`volt_text_free` does, for languages that can't call a C function pointer.

Every binding also has the plain C functions: in C++ they're in namespace `raw`, in Rust in module
`raw`, in Zig in struct `raw`, in C# and Dart in class `Native`, and in Java as the `H_NAME` method
handles.
`--lang` is one of `c`, `cpp`, `rust`, `zig`, `python`, `pyi`, `csharp`, `java`, `go`, `lua`,
`dart`, `swift`, `kotlin`, `ruby`, `node`, `js`, `ts` or `json`. The Python bindings use `ctypes` and load the shared library.
`--lang pyi` writes their type stubs, for editors and type checkers such as mypy.

### The model, for generators of your own

`--lang json` prints what every generator above reads: the package's C interface, as one JSON
object.

```json
{"package": "mathlib", "version": 1,
 "types": [
   {"kind": "struct", "name": "vec2", "c_name": "mathlib_vec2",
    "fields": [{"name": "x", "type": {"kind": "f64"}}, {"name": "y", "type": {"kind": "f64"}}]},
   {"kind": "error_set", "name": "math_error", "codes": [{"name": "NEGATIVE", "code": 3930732238}]},
   {"kind": "class", "name": "counter", "c_name": "mathlib_counter", "free": "counter_free"}],
 "functions": [
   {"name": "counter_add", "class": "counter", "method": "add", "static": false, "doc": "",
    "params": [{"name": "c", "type": {"kind": "handle", "class": "counter", "owned": false, "nullable": false}},
               {"name": "by", "type": {"kind": "i64"}}],
    "returns": {"kind": "i64"}}]}
```

The types are structs (with fields), plain enums (`tag` and `values`), error sets (`codes`),
classes (structs held by a handle), with their `free` function, and traits, with their `table`
(the C struct of their `fns`, each taking the object first). A function's `name` is its C
symbol. A function that belongs to a class has `class`, `method` and `static`, and `NAME_free`
has `frees`. `doc` is the comment above the Volt function.

Each parameter and return type is `{"kind": ...}`:

| kind | what it is in C |
| --- | --- |
| `void`, `bool`, `i8` to `u64`, `isize`, `usize`, `f32`, `f64` | the C type |
| `cstr` | `const char *` |
| `str` | `volt_str`: a pointer and a length (borrowed) |
| `text` | `volt_text`: owned text; call its `drop` with its `owner` when done |
| `pointer` (`to`, `nullable`) | a pointer; `nullable` is false for a Volt `T&` |
| `struct`, `enum` (`name`) | a type from `types` |
| `error` (`set`) | a `uint32_t` code, 0 for none |
| `result` (`error`, `value`, `c_name`) | a struct of `uint32_t error` and `value` |
| `array` (`of`, `len`) | a C array |
| `slice` (`of`), `optional` (`of`) | `{ T *ptr; size_t len }`, `{ T value; bool has }` |
| `handle` (`class`, `owned`, `nullable`) | a pointer to the class; owned ones are freed with its `free` |
| `function` (`params`, `returns`) | an `extern "C"` function pointer |
| `callback` (`params`, `returns`, `c_name`) | two parameters: a C function that gets the data first, and the data (`void *`); one a function returns is the struct `c_name` of the function, the data and its `drop` |
| `object` (`trait`, `owned`) | a trait's object: its table, the object and its `drop` (null when only lent) |

`version` changes when a field or a kind changes meaning.

## In bolt

```toml
[lib]
kind = ["volt", "shared", "static"]   # the usual Volt library, plus libNAME.so and libNAME.a
bindings = ["c", "python"]            # mathlib.h and mathlib.py next to them
```

`bolt build` puts them in `target/<profile>/`, the bindings in `bindings/`. What needs compiling
against the shared library is compiled there too, so it loads as it is: the Node addon
(`bindings/NAME.node`, which `NAME.js` loads), the Lua module (`bindings/lua/NAME.so`, for
`package.cpath`) and the Ruby extension (`bindings/ruby/NAME.so`, for `ruby -I`). bolt warns and
leaves the C file when a language's headers aren't installed. Swift gets a module map
(`bindings/CNAME/module.modulemap`, `import CNAME`) and Kotlin/Native a cinterop definition
(`bindings/NAME.def`). The rest are source files their own toolchains build. `tests/interop` in the
repository has a client for each language.

## pip install and npm install

A Python or Node project can install a Volt library the way it installs anything else: pip and
npm run bolt themselves, as `volt-build` does for Cargo. Both need bolt (from `$BOLT`, else the
PATH) and a `bolt.toml` whose `[lib]` has kind `"shared"` and the bindings for that language.

For pip, copy `interop/pip/volt_build.py` from the repository into the project. It's a build
backend that uses only Python's standard library (3.11 or later), so pip fetches nothing:

```toml
# pyproject.toml, next to bolt.toml ([lib] bindings = ["python", "pyi"])
[build-system]
requires = []
build-backend = "volt_build"
backend-path = ["."]

[project]
name = "mathlib"
version = "0.1.0"
```

`pip install .` (or `pip install` of the sdist) runs `bolt build --release` and installs package
`mathlib`, named after the Volt package: the bindings as its `__init__.py`, with their types, and
`libmathlib.so` beside them.

For npm, copy `interop/npm/volt-install.js` into the package and make it the install script:

```json
{
  "name": "mathlib",
  "version": "0.1.0",
  "main": "target/release/bindings/mathlib.js",
  "types": "target/release/bindings/mathlib.d.ts",
  "files": ["bolt.toml", "lib", "volt-install.js"],
  "scripts": { "install": "node volt-install.js" }
}
```

`npm install` of the package builds it with `bolt build --release` (`[lib] bindings = ["node",
"js", "ts"]`, and Node's headers installed) and loads the addon from `target/release`. npm runs a
dependency's install script only once the project allows it: `npm install-scripts approve
mathlib` writes that into the project's `package.json` (`allowScripts`), and `npm rebuild
mathlib` then builds it.
