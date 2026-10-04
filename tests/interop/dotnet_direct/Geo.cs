// Ordinary C#: nothing in it is written for Volt
using System;
using System.Linq;

namespace Geo {
    public struct Point {
        public double X;
        public double Y;

        public Point(double x, double y) {
            X = x;
            Y = y;
        }

        public double Norm() => Math.Sqrt(X * X + Y * Y);

        public void Scale(double k) {
            X *= k;
            Y *= k;
        }

        public override string ToString() => $"({X}, {Y})";
    }

    public enum Color { Red, Green = 5, Blue }

    public interface IShape {
        double Area();
        string Name { get; }
    }

    public class Shape : IShape {
        public string Label = "shape";
        public virtual double Area() => 0;
        public virtual string Name => "shape";
        public string Describe() => $"{Name} of area {Area()}";
    }

    public class Circle : Shape {
        public static int Made { get; private set; }
        public double R { get; set; }
        public Color Tint { get; set; } = Color.Green;

        public Circle(double r) {
            R = r;
            Made++;
        }

        public override double Area() => 3 * R * R;
        public override string Name => "circle";
    }

    public static class Geom {
        public const int Limit = 10;

        public static int Add(int a, int b) => a + b;
        public static double Add(double a, double b) => a + b + 0.5;
        public static string Upper(string s) => s.ToUpper();
        public static double Sum(double[] xs) => xs.Sum();

        // changes Volt's array: the change comes back
        public static void DoubleAll(int[] xs) {
            for (int i = 0; i < xs.Length; i++) xs[i] *= 2;
        }

        public static int[] Squares(int n) => Enumerable.Range(1, n).Select(i => i * i).ToArray();
        public static string Join(string[] parts, string sep) => string.Join(sep, parts);
        public static string[] Words(string s) => s.Split(' ', StringSplitOptions.RemoveEmptyEntries);

        public static int? Find(int[] xs, int x) {
            int i = Array.IndexOf(xs, x);
            return i < 0 ? null : i;
        }

        public static double Total(IShape a, IShape b) => a.Area() + b.Area();
        public static Color Next(Color c) => c == Color.Red ? Color.Green : c == Color.Green ? Color.Blue : Color.Red;
        public static Point Mid(Point a, Point b) => new Point((a.X + b.X) / 2, (a.Y + b.Y) / 2);
        public static char First(string s) => s[0];
        public static bool Even(int x) => x % 2 == 0;
        public static int Divide(int a, int b) => a / b;

        // Volt can't call these: they're listed in a comment of what bolt writes
        public static T Ident<T>(T x) => x;
        public static void Apply(Func<int, int> f) { }
        public static bool TryParse(string s, out int v) => int.TryParse(s, out v);
    }
}
