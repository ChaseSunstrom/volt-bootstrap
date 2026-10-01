---
title: .NET
description: Calling C# and other .NET code from Volt with the interop/dotnet package.
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
