---
title: Other languages
description: Calling Volt from C, C++, Rust, Zig, Python, JavaScript, C#, Java, Go, Lua, Dart, Swift, Kotlin and Ruby, and calling them from Volt.
sidebar:
  order: 4
---

Everything meets at the C ABI.

## Volt calls them

- **C**: import the header, see [C](/volt-bootstrap/interop/c/).
- **C++**: `use cpp`, see [C++](/volt-bootstrap/interop/cpp/).
- **Rust** and **Zig**: list the crate or the file under `[foreign]` in `bolt.toml`, see
  [Rust and Zig](/volt-bootstrap/interop/rust-and-zig/). Without bolt, declare a
  `#[no_mangle] pub extern "C" fn` (or a Zig `export fn`) with `extern "C" fn` and link the library
  with `--cc`.
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

Cargo and Zig projects can have their build do this, see
[They use Volt](/volt-bootstrap/interop/rust-and-zig/#they-use-volt).

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

| | errors | owned text | slices, optionals | an export struct | callbacks |
| --- | --- | --- | --- | --- | --- |
| C | a struct of the code and the value | `volt_text`, freed with `volt_text_free` | structs | a pointer, and `NAME_free` | a function and a `void *` |
| C++ | throws `error` | `std::string` | from vectors and arrays; `std::optional` | a class that frees itself | `std::function` |
| Rust | `Result<T, Error>` | `String` | `&mut [T]`, `Option` | a type that frees itself when dropped | `&mut dyn FnMut` |
| Python | raises a class per error set, all deriving from `Error` | `str` | lists, `None` | a class with `close()` and `with` | any callable |
| Zig | `Error!T` | `VoltText`, with `bytes()` and `deinit()` | `[]T`, `?T` | a type with `deinit()` | a context and a function |
| JavaScript | throws an `Error` whose `code` is the name | a string | arrays, `null` | a class with `close()` and `Symbol.dispose` | any function |
| C# | throws a `VoltException` subclass per error set | `string` | `Span<T>`, `T?` | an `IDisposable` class over a `SafeHandle` | `Action` or `Func` |
| Java | throws a `VoltException` subclass per error set | `String` | arrays, `null` | an `AutoCloseable` class, freed by a `Cleaner` if not closed | a functional interface |
| Go | `(T, error)`, with an `*Error` value per code for `errors.Is` | `string` | slices; `*T` in, `(T, bool)` out | a type with `Close`, and a finalizer | a `func` |
| Lua | raises a table with its `name` and `code` | a string | sequences (written back), `nil` | a userdata with `close()`, `<close>` and `__gc` | any function |
| Dart | throws a `VoltError` subclass per error set | `String` | `List`s (written back), `null` | a class with `close()`, and a `NativeFinalizer` | any function |
| Swift | throws its error set's enum | `String` | `inout` arrays (written back), `T?` | a class with `close()`, freed by `deinit` | a closure |
| Kotlin/Native | throws a `VoltException` subclass per error set | `String` | primitive arrays (in place) or `List`s, `T?` | an `AutoCloseable` class, freed by a `Cleaner` if not closed | a lambda |
| Ruby | raises a `Mod::Error` subclass per error set | a `String` | `Array`s (written back), `nil` | a class with `close`, freed by the GC | a block or a `Proc` |

### JavaScript and TypeScript

`--lang node` writes the C source of a Node-API addon, which runs in Node.js and in Bun. It
includes the C declarations, so it's one file to compile against the library and node's headers.
`--lang js` writes a loader, and `--lang ts` writes the TypeScript types:

```sh
voltc bindings mathlib --pkg mathlib=lib --lang node > mathlib_node.c
voltc bindings mathlib --pkg mathlib=lib --lang js   > mathlib.js
voltc bindings mathlib --pkg mathlib=lib --lang ts   > mathlib.d.ts
cc -shared -fPIC -I /usr/include/node mathlib_node.c -L. -lmathlib -o mathlib.node
```

```js
const m = require("./mathlib");      // mathlib.node next to it, or $VOLT_MATHLIB_NODE
console.log(m.ml_greet("volt"));     // hello, volt
const c = new m.counter("clicks");   // an export struct is a class
c.add(2);
c.close();                           // or `using c = ...`, or leave it to the garbage collector
try {
    m.ml_sqrt(-1);
} catch (e) {
    console.log(e.code);             // NEGATIVE: the error's name
}
```

Here is how values convert:
- Numbers and `bool` convert directly. A number that doesn't fit the parameter's type throws a
  `RangeError`, and a fraction, NaN or infinity given for an integer throws a `TypeError`.
  64-bit integers also take a `BigInt`. They come back as numbers, which are exact up to 2^53.
- A struct is a plain object. Passed as `T&`, what Volt changes in it comes back to the object.
- A slice is an array, and what Volt writes into its elements comes back too.
- An optional is the value or `null`.
- A callback is any function. It's called during the call it was passed to.
- `str` and owned text are strings.
- An error set's codes are the error names (`m.math_error.NEGATIVE` is `"NEGATIVE"`).
- Each class checks that its methods get an instance of it.

### C#

`--lang csharp` writes one file for .NET 7 or later. It has the structs and enums, a `Native`
class of `[LibraryImport]` declarations, and on top of those the package's functions in a static
class `Api` and a class per export struct. Build it with `AllowUnsafeBlocks`. The library loads as
`libNAME.so`, `NAME.dll` or `libNAME.dylib`.

```csharp
using mathlib;

Console.WriteLine(Api.ml_greet("volt"));            // hello, volt
using (var c = new counter("clicks")) {             // an IDisposable class
    c.add(2);
}
try {
    Api.ml_sqrt(-1);
} catch (math_error e) when (e.Code == math_error.NEGATIVE) {
    Console.WriteLine(e.Name);                      // NEGATIVE
}
```

### Java

`--lang java` writes one class, named after the package, for Java 22 or later. It calls the library
through the FFM API (`java.lang.foreign`), so there is no JNI and no C to compile. It loads
`libNAME.so` (or the library `-Dvolt.NAME.lib` names). Run with `--enable-native-access=ALL-UNNAMED`.

```java
System.out.println(mathlib.ml_greet("volt"));           // hello, volt
try (var c = new mathlib.counter("clicks")) {           // AutoCloseable
    c.add(2);
}
try {
    mathlib.ml_sqrt(-1);
} catch (mathlib.math_error e) {
    System.out.println(e.name);                         // NEGATIVE
}
```

Structs are mutable classes: what Volt changes through a `T&` comes back to the object. Unsigned
integers use the Java type of the same size, as `int` for `u32`.

### Lua

`--lang lua` writes a C module for Lua 5.4 or later. Build it against the library and Lua's headers,
then `require` it:

```sh
voltc bindings mathlib --pkg mathlib=lib --lang lua > mathlib_lua.c
cc -shared -fPIC mathlib_lua.c -L. -lmathlib -o mathlib.so
```

```lua
local m = require("mathlib")
print(m.ml_greet("volt"))                     -- hello, volt
local ok, err = pcall(m.ml_sqrt, -1)
print(err.name == m.math_error.NEGATIVE)      -- true: err is {name = "NEGATIVE", code = ...}
local c <close> = m.counter.new("clicks")     -- closed at the end of the block
c:add(2)
```

Structs are tables with their fields; what Volt changes in one passed by reference comes back
into the table, and so do the elements of a slice (a sequence). An enum is a table of its values,
an error set a table of its names. Integers that don't fit the parameter's type raise an error,
as do wrong types. A callback is any function; an error it raises comes out of the Volt call
(the calls after it are skipped).

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
`throws`. Callbacks are closures.

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
place; a slice of structs is a `List`. Enums are enum classes, error sets `VoltException`
subclasses, and callbacks are lambdas: an exception one throws comes out of the Volt call.

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
fields works too), enums are modules of constants, and error sets are `Mathlib::Error` subclasses
holding their codes. A callback is a block or a `Proc`; an exception it raises comes out of the
Volt call. Integers that don't fit the parameter, and wrong types, raise.

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

The types are structs (with fields), plain enums (`tag` and `values`), error sets (`codes`), and
classes, which are export structs. A class has its `free` function. A function's `name` is its C
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
| `callback` (`params`, `returns`) | two parameters: a C function that gets the data first, and the data (`void *`) |

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
