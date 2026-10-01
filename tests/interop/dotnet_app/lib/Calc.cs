// the C# library the Volt program in src/ calls through interop/dotnet: each method a Volt program
// calls is static and [UnmanagedCallersOnly], with C types in its signature
using System;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Lib;

public static unsafe class Calc
{
    [UnmanagedCallersOnly]
    public static int Add(int a, int b) => a + b;

    [UnmanagedCallersOnly]
    public static double Mean(double* xs, int n)
    {
        double sum = 0;
        for (int i = 0; i < n; i++) sum += xs[i];
        return sum / n;
    }

    // text in as UTF-8, text out with StringToCoTaskMemUTF8 (dotnet::take_string frees it)
    [UnmanagedCallersOnly]
    public static byte* Greet(byte* who)
    {
        var name = Marshal.PtrToStringUTF8((IntPtr)who);
        return (byte*)Marshal.StringToCoTaskMemUTF8($"hello, {name} from .NET");
    }

    [UnmanagedCallersOnly]
    public static byte* ToJson(int x, int y)
    {
        return (byte*)Marshal.StringToCoTaskMemUTF8(JsonSerializer.Serialize(new { x, y }));
    }

    // a Volt function passed in and called back
    [UnmanagedCallersOnly]
    public static int Apply(delegate* unmanaged<int, int> f, int x) => f(x) + 1;

    // an exception can't cross into Volt: catch it and return an error code
    [UnmanagedCallersOnly]
    public static int Divide(int a, int b, int* result)
    {
        try
        {
            *result = a / b;
            return 0;
        }
        catch (DivideByZeroException)
        {
            return 1;
        }
    }
}
