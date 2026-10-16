// Ordinary C# too: ref and out parameters, delegates, generic methods and a generic class
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Geo {
    public delegate double Op(double a, double b);

    public static class Gen {
        // ref: what C# writes comes back (a number, a struct, a class handle C# points elsewhere)
        public static void Bump(ref int x) => x += 1;
        public static void Shift(ref Point p, double dx) => p.X += dx;
        public static void Swap(ref Shape s) => s = new Circle(5);

        // out: extra results (one out of a void method is the result itself)
        public static bool TryParse(string s, out int v) => int.TryParse(s, out v);
        public static void Half(int x, out int h) => h = x / 2;
        public static void Split(double x, out int whole, out double frac) {
            whole = (int)x;
            frac = x - whole;
        }

        // delegates: Func, Action and a named one take a Volt fn value; a delegate result is a value
        // with call()
        public static int Apply(Func<int, int> f, int x) => f(x);
        public static int Count(int n, Action<int> each) {
            for (int i = 0; i < n; i++) each(i);
            return n;
        }
        public static double Fold(double[] xs, Op op) {
            double acc = 0;
            foreach (var x in xs) acc = op(acc, x);
            return acc;
        }
        public static Func<int, int> Adder(int n) => x => x + n;

        // a delegate C# keeps, called on a later call, and one called on another thread
        static Func<int, int> kept;
        public static void Keep(Func<int, int> f) => kept = f;
        public static int CallKept(int x) => kept(x);
        public static int OnThread(Func<int, int> f, int x) => Task.Run(() => f(x)).Result;

        // generic methods: each instance a program uses is built
        public static T Max<T>(T a, T b) where T : IComparable<T> => a.CompareTo(b) >= 0 ? a : b;
        public static T Pick<T>(T[] xs, int i) => xs[i];
        public static bool TryFirst<T>(T[] xs, out T v) {
            v = xs.Length > 0 ? xs[0] : default;
            return xs.Length > 0;
        }

        // an overload with an out parameter beside one without: the plain one keeps the name
        public static int Parse(string s) => int.Parse(s);
        public static bool Parse(string s, out int v) => int.TryParse(s, out v);

        // [In, Out] ref is a ref
        public static void Fill([In, Out] ref int x) => x = 99;

        // a delegate that returns its own type: left out, the rest still imported
        public delegate Step Step(int x);
        public static Step Start() => null;

        // Volt can't call these: they're listed in a comment of what bolt writes
        public static void Grow(ref string s) => s += "!";
        public static int Corner(int[,] m) => m[0, 0];
    }

    // an out parameter on an instance method
    public class Counter {
        int n;
        public bool Next(int limit, out int v) {
            v = n++;
            return v < limit;
        }
    }

    // a class and a generic class of one name: the plain one is imported
    public class Tagged {
        public string Name => "tagged";
    }

    public class Tagged<T> {
        public T Value;
    }

    // a class nested in a generic class: left out
    public class Outer<T> {
        public class Inner {
            public int N => 1;
        }
    }

    // a generic class: each instance a program names is built
    public class Box<T> {
        public T Value;
        public Box(T v) => Value = v;
        public T Get() => Value;
        public void Set(T v) => Value = v;
        public string Show() => $"Box({Value})";
    }
}
