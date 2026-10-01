// C# calls the Volt library through voltc bindings --lang csharp: errors are thrown (one exception
// class per error set), owned text comes back as a string, an export struct is IDisposable
using System;
using System.Collections.Generic;
using mathlib;

Console.WriteLine($"add {Api.ml_add(2, 3)}");
var a = new vec2 { x = 1, y = 2 };
var b = new vec2 { x = 3, y = 4 };
Console.WriteLine($"dot {Api.ml_dot(a, b)}");
Api.ml_scale(ref a, 2);
Console.WriteLine($"scale {a.x} {a.y}");
Console.WriteLine($"len {Api.ml_len("hello")}");
Console.WriteLine($"next {(int)Api.ml_next(color.GREEN)}");
Console.WriteLine($"sqrt {Api.ml_sqrt(9)} 1");
try
{
    Api.ml_sqrt(-1);
}
catch (math_error e) when (e.Code == math_error.NEGATIVE)
{
    Console.WriteLine("error negative");
}
Console.WriteLine($"greet {Api.ml_greet("volt")}");
Console.WriteLine($"repeat {Api.ml_repeat("ab", 2)}");
try
{
    Api.ml_repeat("ab", -1);
}
catch (VoltException e)
{
    Console.WriteLine($"repeat {e.Name.ToLowerInvariant()}");
}
Console.WriteLine($"sum {Api.ml_sum(new double[] { 1, 2, 3.5 })}");
int[] ys = { 4, 5, 6 };
Console.WriteLine($"find {Api.ml_find(ys, 6)} {(Api.ml_find(ys, 9) == null ? "none" : "?")}");
var seen = new List<int>();
Api.ml_each(ys, x => seen.Add(x));
Console.WriteLine($"each {string.Join(" ", seen)} = {seen.Sum()}");
using (var c = new counter("clicks"))
{
    c.add(2);
    Console.WriteLine($"counter {c.name()} {c.add(3)}");
    try
    {
        c.take(9);
    }
    catch (math_error e)
    {
        Console.WriteLine($"take {e.Name.ToLowerInvariant()}");
    }
}

static class Ext
{
    public static int Sum(this List<int> xs)
    {
        int s = 0;
        foreach (var x in xs)
        {
            s += x;
        }
        return s;
    }
}
