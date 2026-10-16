---
title: .NET
description: Calling C# and other .NET code from Volt by importing it like a header, and Volt from C# through generated bindings.
sidebar:
  order: 7
---

## Volt calls .NET

C# sources and .NET assemblies are imported like a header. Nothing in the C# is written for Volt
(no `[UnmanagedCallersOnly]`), and the Volt code has no runtime configs, start calls or function
pointers: bolt builds the sources with `dotnet build`, asks .NET what the assembly exports, and
writes a C# shim and the Volt declarations that call it. .NET starts the first time it's called.

```volt ignore
use std::io;
use { "Geo.cs" } as geo;             // or { "Lib.dll" }

fn main() -> void {
    var p = geo::Point::new(3.0, 4.0);                 // a struct of plain fields: a Volt struct
    p.Scale(2.0);
    var c = geo::Circle::new(2.0);                     // a class: a handle
    c.set_R(1.0);                                      // a property: R() and set_R(v)
    std::println("{} {} {}", p.X, c.Area(), geo::Geom::Upper("quiet"));   // 6 3 QUIET
    val s = c.as_IShape();                             // the same object, as an interface it has
    std::println("{}", geo::Geom::Total(&s, &s));      // 6
}
```

| .NET | Volt |
| --- | --- |
| a class, interface or static class | a handle: .NET's collector keeps the object while Volt holds it, and a copy refers to the same object |
| a struct whose fields are all public, settable numbers, `bool`s, enums or such structs | a Volt struct with those fields, passed by value |
| any other struct | a handle |
| `new T(...)` | `T::new(...)`, one per public constructor |
| a public method | a method, or `T::F(...)` for a static one; overloads stay overloads |
| a property or public field | `X()` and, when it can be set, `set_X(v)`; `T::X()` for a static one (constants too) |
| an imported base class or interface `B` | `as_B()`: the same object, as a `B` |
| an `enum` | a Volt enum with the same values |
| `bool`, `sbyte`…`ulong`, `float`, `double` | the same; `char` is `u32` |
| `string` | `str` in, `std::string` out (`null` is `""`) |
| `T[]` of those and of `string` | `T[..]` in (what .NET changes in it comes back), `std::vec<T>` out |
| `int?` and the like | `i32?` |
| a `ref` parameter of a number, `bool`, struct or class | `T&`: what .NET writes comes back (a class's handle holds the object .NET pointed it at) |
| `out` parameters | results: `bool TryParse(string s, out int v)` is `(bool, v: i32)`, a `void` method's one `out` its value |
| a delegate parameter (`Func<>`, `Action<>`, a named one) of numbers, `bool`s, `char`s and `string`s | a Volt fn value (`\|\| (x: i32) -> i32 { ... }`), which .NET may keep, call later or call on another thread; it's freed when .NET collects the delegate (one still alive when the program ends is never freed: .NET runs no finalizers at exit) |
| a delegate result | a value with `call(...)` |
| a generic method (`T Max<T>(T a, T b)`) or class (`Box<T>`) | a Volt generic: `Gen::Max<i32>(3, 9)`, `geo::Box<i32>::new(3)`; each instance the program uses is built, and one the C# compiler rejects (a type that doesn't meet a constraint) is an error at the call with its reason. A type argument is a number, `std::string` or one of the import's types |

An exception stops the program with its type and message, as a Volt panic does (.NET declares no
exceptions to make an error of). What the table doesn't cover is left out — a `ref` of text or of
an enum, a generic method in a generic class, a delegate with `ref` or `out` parameters, a
multi-dimensional array — listed in a comment of the generated declarations (`VOLT_SHOW_IMPORT=1
voltc check main.volt` prints them). There each Volt fn has the declaration it calls above it, in C#'s
spelling (`// .NET: public double Norm()`), which an editor's hover shows. bolt needs the .NET SDK:
`$DOTNET`, else `$DOTNET_ROOT/dotnet`, else `dotnet` on the PATH; the program links its `libhostfxr`
with an rpath, and an assembly's own dependencies are found next to it.

## The interop/dotnet package

The `interop/dotnet` package (in the repository) starts the .NET runtime inside a Volt program
through hostfxr, the library `dotnet` itself uses, for calls made by hand. Its build file finds the install that
`dotnet --list-runtimes` reports (`$DOTNET_ROOT/dotnet` when that's set) and links `libhostfxr`
with an rpath to it.

```toml
# bolt.toml
[dependencies]
dotnet = { path = "../volt/interop/dotnet" }
```

The C# side is a class library built with `EnableDynamicLoading`, which writes the
`NAME.runtimeconfig.json` the runtime starts from. Each method Volt calls is `static` and
`[UnmanagedCallersOnly]`, with C types in its signature:

```xml
<!-- Lib.csproj -->
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <EnableDynamicLoading>true</EnableDynamicLoading>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
  </PropertyGroup>
</Project>
```

```csharp
using System.Runtime.InteropServices;

namespace Lib;

public static unsafe class Calc
{
    [UnmanagedCallersOnly]
    public static int Add(int a, int b) => a + b;

    [UnmanagedCallersOnly]
    public static byte* Greet(byte* who) =>
        (byte*)Marshal.StringToCoTaskMemUTF8($"hello, {Marshal.PtrToStringUTF8((nint)who)}");

    [UnmanagedCallersOnly]
    public static int Apply(delegate* unmanaged<int, int> f, int x) => f(x) + 1;
}
```

`rt.function` loads a method and gives its address, and `@cast` makes it a Volt function:

```volt ignore
use std::io;

extern "C" fn twice(x: i32) -> i32 {
    return x * 2;
}

fn run(rt: dotnet::runtime&) -> dotnet::dotnet_error!void {
    val dll = "lib/bin/Lib.dll";
    val add = @cast<extern "C" fn(i32, i32) -> i32>(try rt.function(dll, "Lib.Calc, Lib", "Add"));
    std::println("{}", add(2, 40));                                   // 42
    val greet = @cast<extern "C" fn(cstr) -> void*>(try rt.function(dll, "Lib.Calc, Lib", "Greet"));
    std::println("{}", dotnet::take_string(greet("volt")));           // hello, volt
    val apply = @cast<extern "C" fn(extern "C" fn(i32) -> i32, i32) -> i32>(try rt.function(dll, "Lib.Calc, Lib", "Apply"));
    std::println("{}", apply(twice, 20));                             // 41
}

fn main() -> !void {
    var rt = try dotnet::start("lib/bin/Lib.runtimeconfig.json");
    try run(&rt);
}
```

| | |
| --- | --- |
| `dotnet::start(runtimeconfig)` | starts the runtime a library's `NAME.runtimeconfig.json` asks for |
| `rt.function(assembly, type, method)` | a static `[UnmanagedCallersOnly]` method's address; `type` is `"Namespace.Type, Assembly"` |
| `dotnet::take_string(p)` | the text of a string C# returned from `Marshal.StringToCoTaskMemUTF8`, which it frees |

Arguments and results are C types: integers, `float`, `double`, pointers (`f64*` for a `double*`,
`cstr` for a `byte*` holding UTF-8) and function pointers both ways (`delegate* unmanaged<...>` in
C#). A missing assembly, type or method is `dotnet_error::FAILED` with hostfxr's code. An exception
can't cross into Volt: an exception that escapes an `[UnmanagedCallersOnly]` method ends the
process, so catch it in C# and return an error code.

The runtime starts once per process and stays loaded until the process ends. One process can load
any number of assemblies.

## C# calls Volt

A Volt library that lists `csharp` among its bindings gets one C# file from `bolt build`
(`target/debug/bindings/NAME.cs`), for .NET 7 or later (.NET 8 when a struct holds an array of
text or of structs, which C# gets as an inline array, and .NET 9 when a callback gives back a
slice, a `Func` returning a `Span`). It has the structs and enums, a `Native`
class of `[LibraryImport]` declarations, and on top of those the package's functions in a static
class `Api` and a class per export struct.

The examples here use `greet`, the library every client in
[examples/interop/calls-volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt)
calls: `export fn add(a: i64, b: i64) -> i64`, `export fn hello(name: str) -> std::string`, and an
`export struct tally` with `tally_new`, `tally_add` and `tally_name`. What `export` means, and what
crosses as what, is in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt).

```toml
# bolt.toml of the Volt library
[lib]
kind = ["shared"]
bindings = ["csharp"]
```

```csharp
using greet;

Console.WriteLine($"add {Api.add(2, 3)}");        // add 5
Console.WriteLine(Api.hello("volt"));             // hello, volt
using (var c = new tally("clicks"))               // an IDisposable class over a SafeHandle
{
    c.add(1);
    Console.WriteLine($"{c.name()} {c.add(2)}");  // clicks 3
}
```

Add the file to the project (`<Compile Include="..." />`) and build with `AllowUnsafeBlocks`. The
library loads as `libNAME.so`, `NAME.dll` or `libNAME.dylib`, from where the system looks for
libraries; `bolt build` puts it in `target/debug`:

```sh
bolt build
LD_LIBRARY_PATH=/path/to/greet/target/debug dotnet run   # DYLD_LIBRARY_PATH on macOS
```

An error set becomes a `VoltException` subclass whose `Code` and `Name` say which error it was;
slices are `Span<T>`, optionals `T?`, and a callback an `Action` or a `Func`. Structs are C#
structs, and one Volt takes by reference (`v: vec2&`) is passed `ref`, so what Volt changes comes
back; enums are C# enums. A number by reference (`n: i32*`, `x: f64&`) is a pointer (`int*`,
`double*`), passed from `unsafe` code.

### Every shape

C# takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape) C does:

- **Owned values as parameters.** Text (`std::string`) is a `string`, which Volt copies. A handle
  by value is given to the fn: the class lets its handle go (`Release()` does that by hand), and
  Volt deletes it. One lent to a call that hasn't returned can't be disposed of or given away
  until it does (a callback trying throws `InvalidOperationException`), nor lent and given in one
  call.
- **Traits.** A Volt trait is an interface to implement. A fn taking `s: shape&` lends Volt the
  object for the call; one taking `s: shape` gives it, and Volt calls `Dispose()` on it (when it's
  `IDisposable`) once it's done. A Volt value of the trait comes back as a `volt_shape`, which
  implements the interface and frees Volt's value on `Dispose()` (or in its finalizer).
- **Callbacks taking and giving text, handles and errors.** Text is a `string` both ways, a
  handle is its class (one Volt lends is a class that never frees it), and an `E!T` callback
  returns its `T` or throws: `VoltException.For(code)` makes the exception for one of the error
  set's codes. Any other exception comes out of the call that took the callback.
- **Lists, and text and handles in slices and optionals.** A `std::vec<T>` comes back as a
  `List<T>` (of `string`s, or of the classes, each the caller's). As a parameter it takes any
  `IEnumerable<T>`, and so does a slice of text or of an export struct (lent for the call; a
  list's handles are given). An optional text or handle is a `string?` or a nullable class, and an
  optional in a slice converts from `T?`.
- **Closures given back.** A fn returning `fn(A) -> R` gives a `closureN` with `Invoke`, which
  frees Volt's closure on `Dispose()` (or in its finalizer).

With a library like the one there (a `shape` trait, `describe(s: shape&)`, `grow_twice(s: shape)`,
`shout`, `greeter` and `owners`):

```csharp
sealed class Circle : shape, IDisposable
{
    double r = 1;
    public double area() => 3 * r * r;
    public string name() => "circle";
    public void grow(double by) => r += by;
    public void Dispose() => Console.WriteLine("circle gone");
}

Console.WriteLine(Api.describe(new Circle()));        // circle of area 3, lent
Console.WriteLine(Api.grow_twice(new Circle()));      // circle gone, then 27: given
Console.WriteLine(Api.shout(s => s + "!", "hey"));    // hey!
using (var hi = Api.greeter())
{
    Console.WriteLine(hi.Invoke("volt"));             // hello, volt
}
using var ann = account.open("ann");
var names = Api.owners(new[] { ann });                // a List<string>: ann
```

A method of an interface that throws doesn't unwind into Volt: the exception is kept, the
method gives Volt an empty value, and the call that lent or gave the object throws it when it
returns.
