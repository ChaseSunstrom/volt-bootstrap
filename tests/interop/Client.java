// Java calls the Volt library through voltc bindings --lang java (the FFM API): errors are thrown
// (one exception class per error set), owned text comes back as a String, an export struct is
// AutoCloseable
import java.util.ArrayList;
import java.util.List;

public class Client {
    public static void main(String[] args) {
        System.out.println("add " + mathlib.ml_add(2, 3));
        var a = new mathlib.vec2(1, 2);
        var b = new mathlib.vec2(3, 4);
        System.out.println("dot " + fmt(mathlib.ml_dot(a, b)));
        mathlib.ml_scale(a, 2);
        System.out.println("scale " + fmt(a.x) + " " + fmt(a.y));
        System.out.println("len " + mathlib.ml_len("hello"));
        System.out.println("next " + mathlib.ml_next(mathlib.color.GREEN).value);
        System.out.println("sqrt " + fmt(mathlib.ml_sqrt(9)) + " 1");
        try {
            mathlib.ml_sqrt(-1);
        } catch (mathlib.math_error e) {
            System.out.println("error " + (e.code == mathlib.math_error.NEGATIVE ? "negative" : "?"));
        }
        System.out.println("greet " + mathlib.ml_greet("volt"));
        System.out.println("repeat " + mathlib.ml_repeat("ab", 2));
        try {
            mathlib.ml_repeat("ab", -1);
        } catch (mathlib.VoltException e) {
            System.out.println("repeat " + e.name.toLowerCase());
        }
        System.out.println("sum " + fmt(mathlib.ml_sum(new double[] {1, 2, 3.5})));
        int[] ys = {4, 5, 6};
        System.out.println("find " + mathlib.ml_find(ys, 6) + " " + (mathlib.ml_find(ys, 9) == null ? "none" : "?"));
        List<Integer> seen = new ArrayList<>();
        mathlib.ml_each(ys, seen::add);
        int total = 0;
        StringBuilder each = new StringBuilder("each");
        for (int x : seen) {
            each.append(" ").append(x);
            total += x;
        }
        System.out.println(each + " = " + total);
        try (var c = new mathlib.counter("clicks")) {
            c.add(2);
            System.out.println("counter " + c.name() + " " + c.add(3));
            try {
                c.take(9);
            } catch (mathlib.math_error e) {
                System.out.println("take " + e.name.toLowerCase());
            }
        }
    }

    // numbers as the other clients print them: 11, not 11.0
    static String fmt(double d) {
        return d == Math.rint(d) ? Long.toString((long) d) : Double.toString(d);
    }
}
