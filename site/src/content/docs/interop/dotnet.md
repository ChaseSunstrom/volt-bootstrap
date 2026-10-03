---
title: .NET
description: Calling C# and other .NET code from Volt with the interop/dotnet package, and Volt from C# through generated bindings.
sidebar:
  order: 7
---

The `interop/dotnet` package (in the repository) starts the .NET runtime inside a Volt program
through hostfxr, the library `dotnet` itself uses. Its build file finds the install that
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
(`target/debug/bindings/NAME.cs`), for .NET 7 or later. It has the structs and enums, a `Native`
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
slices are `Span<T>`, optionals `T?`, and a callback an `Action` or a `Func`.
