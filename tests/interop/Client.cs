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
Console.WriteLine($"clash {Api.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14)}");
var tg = Api.ml_tags_make();
Console.Write($"tags {tg.from} {tg.type} {tg.self} {tg.@int}");
tg.@int = 5;
Console.WriteLine($" {Api.ml_tags_sum(tg)}");
int bp = 7;
double bq = 2.5;
unsafe
{
    Api.ml_bump(&bp, &bq);
}
Console.WriteLine($"bump {bp} {bq}");
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
// structs with text, an array and a struct in them (in, out, in a span, from a lambda), one with a
// pointer, E!T as a parameter (a value, or a VoltException)
var la = new ml_label { name = "ab", sizes = new[] { 1, 2, 3 }, at = new vec2 { x = 7, y = 0 } };
Console.WriteLine($"label {Api.ml_label_len(la)}");
var lb = Api.ml_label_of("ab", 3);
Console.WriteLine($"label_of {lb.name} {lb.sizes[0]} {lb.sizes[1]} {lb.sizes[2]} {lb.at.x}");
Console.WriteLine($"labels {Api.ml_labels_len(new[] { la, lb })}");
unsafe
{
    Console.WriteLine($"holder {Api.ml_holder_k(new ml_holder { p = null, k = 3 })}");
}
Console.WriteLine($"or {Api.ml_or(4.5, 9.5)} {Api.ml_or(VoltException.For(math_error.NEGATIVE), 9.5)}");
Console.WriteLine($"ask {Api.ml_ask(k => new ml_label { name = "abc", sizes = new[] { k, k, k }, at = new vec2 { x = 3, y = 0 } })}");
Api.ml_relabel(ref lb, 4);
Console.WriteLine($"relabel {lb.name} {lb.sizes[0]} {lb.sizes[1]} {lb.sizes[2]}");
Console.WriteLine($"count {Api.ml_labels_count(new[] { la, lb })}");
Console.WriteLine($"note {Api.ml_note_len(new ml_note { str = "abc", c = 1, k = 3 })}");
Console.WriteLine($"or_label {Api.ml_or_label(la)} {Api.ml_or_label(VoltException.For(math_error.NEGATIVE))}");
Console.WriteLine($"given {Api.ml_sum_given(3, k => new long[] { k, 10L * k })} {Api.ml_area_given(k => new vec2[] { new vec2 { x = 1.5, y = k }, new vec2 { x = 2, y = 3.25 } })}");
long[][][] deep = [[[1, 2], [3]], [[4]]];
var d = Api.ml_deep(deep);
Console.WriteLine($"deep {d} {deep[0][0][1]} {deep[1][0][0]} words {Api.ml_words([["ab", "c"], [], ["def"]])}");
Console.WriteLine($"text_given {Api.ml_text_given(k => new[] { "ab", "cde" })} {Api.ml_labels_given(k => new ml_label[] { new ml_label { name = "abc", sizes = new[] { k, k, k }, at = new vec2 { x = 3, y = 0 } }, new ml_label { name = "de", sizes = new[] { 1, 1, 1 }, at = new vec2 { x = 0, y = 0 } } })}");
Console.WriteLine($"turn {Api.ml_turn(a => new[] { a[2], a[1], a[0] })}");

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
