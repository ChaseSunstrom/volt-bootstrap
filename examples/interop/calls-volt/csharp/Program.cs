// C# calls the Volt library greet through its bindings (bindings/greet.cs, P/Invoke): owned text
// comes back as a string, an export struct is IDisposable
using System;
using greet;

Console.WriteLine($"add {Api.add(2, 3)}");
Console.WriteLine(Api.hello("volt"));
using (var c = new tally("clicks"))
{
    c.add(1);
    var n = c.add(2);
    Console.WriteLine($"{c.name()} {n}");
}
