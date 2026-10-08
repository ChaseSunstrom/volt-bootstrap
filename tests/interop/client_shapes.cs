// C# calls shapelib (voltc bindings --lang csharp): a generic's instances, a struct held by a class
// with methods, owned values passed in, a Volt trait as an interface both ways, callbacks taking and
// giving text, handles and errors, closures given back (IDisposable, called with Invoke), lists,
// and optional text and handles; the library's leak report goes to stderr last
using System;
using System.Runtime.InteropServices;
using shapelib;

Extras();
Console.WriteLine($"biggest {Api.biggest_i32(new[] { 3, 9, 4 })} {Api.biggest_f64(new[] { 1.5, 0.5 })}");
var a = account.open("ann");
a.deposit(250);
a.rename("bea");
long n = a.deposit(50);
Console.WriteLine($"account {a.owner()} {n}");
n = Api.visit(a, b => b.deposit(1));
Console.WriteLine($"visit {n} get {a.get()}");
n = Api.close_account(a);
Console.WriteLine($"closed {n} {Api.closed_accounts()}");
var c = new Circle(1);
Console.WriteLine(Api.describe(c));
// given: Volt disposes it when it's done
Console.WriteLine($"grown {Api.grow_twice(new Circle(1))}");
using (var sq = Api.make_square(2))
{
    sq.grow(1);
    Console.WriteLine($"{sq.name()} {sq.area()} {Api.describe(sq)}");
}
Console.WriteLine(Api.shout(s => s + "!", "hey"));
Func<int, int> twice = x => x > 5 ? throw VoltException.For(bank_error.OVERDRAWN) : x * 2;
Console.Write($"try {Api.try_twice(twice, 1)}");
try
{
    Api.try_twice(twice, 4);
}
catch (bank_error e)
{
    Console.WriteLine($" {e.Name}");
}
n = Api.opened_by(owner =>
{
    var b = account.open(owner);
    b.deposit(7);
    return b;
});
Console.WriteLine($"opened {n}");
Console.WriteLine($"closed {Api.closed_accounts()}");
using (var d = Api.doubler())
using (var hi = Api.greeter())
{
    Console.WriteLine($"{d.Invoke(21)} {hi.Invoke("volt")}");
}
Lists();
InUse();
c.Dispose();
// what the library still holds (it was built with --leak-check)
var lib = NativeLibrary.Load("shapelib", typeof(Api).Assembly, null);
Console.Error.WriteLine($"volt live: {(ulong)Marshal.ReadIntPtr(NativeLibrary.GetExport(lib, "volt_live_allocs"))}");

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
static void Extras()
{
    var ok = true;
    try
    {
        Api.@checked(x =>
        {
            if (x <= 0)
            {
                throw VoltException.For(bank_error.OVERDRAWN);
            }
        }, 1);
    }
    catch (VoltException)
    {
        ok = false;
    }
    var err = "";
    try
    {
        Api.@checked(_ => throw VoltException.For(bank_error.OVERDRAWN), 1);
    }
    catch (bank_error e)
    {
        err = e.Name;
    }
    Console.WriteLine($"checked {(ok ? "true" : "false")} {err}");
    using (var lim = Api.limiter())
    {
        lim.Invoke(3);
        try
        {
            lim.Invoke(12);
        }
        catch (bank_error e)
        {
            Console.WriteLine($"limit true {e.Name}");
        }
    }
    using (var sign = Api.labeler())
    {
        Console.WriteLine($"sign {sign.Invoke(5)} {sign.Invoke(-1)}");
    }
}

// an account a running call lent to Volt can't be closed or given away by a callback meanwhile (it
// prints only what was wrongly accepted)
static void InUse()
{
    using var a = account.open("busy");
    try
    {
        Api.visit(a, b => { a.Dispose(); return 0; });
        Console.WriteLine("accepted: closing an account a call holds");
    }
    catch (InvalidOperationException)
    {
    }
    try
    {
        Api.visit(a, b => Api.close_account(a));
        Console.WriteLine("accepted: giving away an account a call holds");
    }
    catch (InvalidOperationException)
    {
    }
    try
    {
        Api.visit_over(new[] { a }, b => { a.Dispose(); return 0; });
        Console.WriteLine("accepted: closing an account a call holds in an array");
    }
    catch (InvalidOperationException)
    {
    }
    try
    {
        Api.lend_give(a, a);
        Console.WriteLine("accepted: lending and giving one account in one call");
    }
    catch (InvalidOperationException)
    {
    }
    // a callback that throws leaves what the call lent as it was (disposable after)
    try
    {
        Api.visit_then(b => throw new ArgumentException("thrown"), a);
    }
    catch (ArgumentException)
    {
    }
}

// lists (List<T> out, any IEnumerable<T> in), slices of text and handles, optional text and handles
static void Lists()
{
    var a = account.open("ann");
    a.deposit(5);
    var b = account.open("bobby");
    b.deposit(9);
    var both = new[] { a, b };
    var os = Api.owners(both);
    Console.WriteLine($"owners {os.Count} {os[0]} {os[1]}");
    Console.Write($"richest {Api.richest(both)}");
    Console.WriteLine($" after {a.get()} {b.get()}");
    var opened = Api.open_all(new[] { "cy", "dee" });
    Console.WriteLine($"opened {opened.Count} {opened[1].owner()}");
    // each handle is the caller's
    foreach (var x in opened)
    {
        x.Dispose();
    }
    var sq = Api.squares_upto(4);
    Console.WriteLine($"squares {sq.Count} {sq[3]} sum {Api.sum_all(sq)}");
    var parts = new[] { "a", "b", "c" };
    Console.WriteLine($"joined {Api.joined(parts, "-")} total {Api.total_len(parts)}");
    Console.WriteLine($"{Api.greeting("ann")}; {Api.greeting(null)}");
    string? n1 = Api.nickname(a), n2 = Api.nickname(b);
    Console.WriteLine($"nick {(n1 != null ? 1 : 0)} {n1} {(n2 != null ? 1 : 0)}");
    var c = Api.open_if("eve", true);
    var d = Api.open_if("x", false);
    Console.WriteLine($"open_if {(c != null ? 1 : 0)} {(d == null ? 1 : 0)}");
    Console.WriteLine($"close_if {Api.close_if(c)} {Api.close_if(null)}");
    // given to Volt: a and b let their handles go
    Console.WriteLine($"close_all {Api.close_all(both)}");
    Console.WriteLine($"some {Api.count_some(new opt_i64[] { 1, null, 3 })}");
    Console.WriteLine($"lists closed {Api.closed_accounts()}");
}

// C#'s own shape: Volt disposes one it was given when it's done with it
sealed class Circle : shape, IDisposable
{
    double r;

    public Circle(double r) => this.r = r;

    public double area() => 3 * r * r;

    public string name() => "circle";

    public void grow(double by) => r += by;

    public void Dispose() => Console.WriteLine("circle gone");
}
