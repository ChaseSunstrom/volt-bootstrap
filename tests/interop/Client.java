// Java calls the Volt library through voltc bindings --lang java (the FFM API): errors are thrown
// (one exception class per error set), owned text comes back as a String, an export struct is
// AutoCloseable
import java.lang.foreign.MemorySegment;
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
        System.out.println("clash " + mathlib.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14));
        var tg = mathlib.ml_tags_make();
        System.out.print("tags " + tg.from + " " + tg.type + " " + tg.self + " " + tg.int_);
        tg.int_ = 5;
        System.out.println(" " + mathlib.ml_tags_sum(tg));
        try (var ar = java.lang.foreign.Arena.ofConfined()) {
            var bp = ar.allocate(java.lang.foreign.ValueLayout.JAVA_INT);
            bp.set(java.lang.foreign.ValueLayout.JAVA_INT, 0, 7);
            var bq = ar.allocate(java.lang.foreign.ValueLayout.JAVA_DOUBLE);
            bq.set(java.lang.foreign.ValueLayout.JAVA_DOUBLE, 0, 2.5);
            mathlib.ml_bump(bp, bq);
            System.out.println("bump " + bp.get(java.lang.foreign.ValueLayout.JAVA_INT, 0) + " " + fmt(bq.get(java.lang.foreign.ValueLayout.JAVA_DOUBLE, 0)));
        }
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
        // structs with text, an array and a struct in them (in, out, in an array, from a lambda), one
        // with a pointer, E!T as a parameter (a VoltResult)
        var la = new mathlib.ml_label("ab", new int[] {1, 2, 3}, new mathlib.vec2(7, 0));
        System.out.println("label " + mathlib.ml_label_len(la));
        var lb = mathlib.ml_label_of("ab", 3);
        System.out.println("label_of " + lb.name + " " + lb.sizes[0] + " " + lb.sizes[1] + " " + lb.sizes[2] + " " + lb.at.x);
        System.out.println("labels " + mathlib.ml_labels_len(new mathlib.ml_label[] {la, lb}));
        System.out.println("holder " + mathlib.ml_holder_k(new mathlib.ml_holder(MemorySegment.NULL, 3)));
        System.out.println("or " + mathlib.ml_or(mathlib.VoltResult.ok(4.5), 9.5) + " " + mathlib.ml_or(mathlib.VoltResult.err(mathlib.VoltException.of(mathlib.math_error.NEGATIVE)), 9.5));
        System.out.println("ask " + mathlib.ml_ask(k -> new mathlib.ml_label("abc", new int[] {k, k, k}, new mathlib.vec2(3, 0))));
        mathlib.ml_relabel(lb, 4);
        System.out.println("relabel " + lb.name + " " + lb.sizes[0] + " " + lb.sizes[1] + " " + lb.sizes[2]);
        System.out.println("count " + mathlib.ml_labels_count(new mathlib.ml_label[] {la, lb}));
        System.out.println("note " + mathlib.ml_note_len(new mathlib.ml_note("abc", 1, 3)));
        System.out.println("or_label " + mathlib.ml_or_label(mathlib.VoltResult.ok(la)) + " " + mathlib.ml_or_label(mathlib.VoltResult.err(mathlib.VoltException.of(mathlib.math_error.NEGATIVE))));
        System.out.println("given " + mathlib.ml_sum_given(3, k -> new long[] {k, 10L * k}) + " " + mathlib.ml_area_given(k -> new mathlib.vec2[] {new mathlib.vec2(1.5, k), new mathlib.vec2(2, 3.25)}));
        long[][][] deep = {{{1, 2}, {3}}, {{4}}};
        long d = mathlib.ml_deep(deep);
        System.out.println("deep " + d + " " + deep[0][0][1] + " " + deep[1][0][0] + " words " + mathlib.ml_words(new String[][] {{"ab", "c"}, {}, {"def"}}));
        System.out.println("text_given " + mathlib.ml_text_given(k -> new String[] {"ab", "cde"}) + " " + mathlib.ml_labels_given(k -> new mathlib.ml_label[] {new mathlib.ml_label("abc", new int[] {k, k, k}, new mathlib.vec2(3, 0)), new mathlib.ml_label("de", new int[] {1, 1, 1}, new mathlib.vec2(0, 0))}));
        System.out.println("turn " + mathlib.ml_turn(t -> new int[] {t[2], t[1], t[0]}));
        System.out.println("turner " + mathlib.ml_turned(t -> new int[] {t[2], t[1], t[0]}) + " flipped " + mathlib.ml_flipped(mathlib.ml_flipper()));
        var po = mathlib.ml_pair_of("ab", "cd");
        var shelf = new mathlib.ml_shelf(new mathlib.ml_label[] {new mathlib.ml_label("abc", new int[] {2, 2, 2}, new mathlib.vec2(3, 0)), new mathlib.ml_label("de", new int[] {1, 1, 1}, new mathlib.vec2(0, 0))}, 1);
        var bk = mathlib.ml_labels_back(shelf.labels);
        System.out.println("pair " + mathlib.ml_pair_len(new mathlib.ml_pair(new String[] {"ab", "cde"}, 1)) + " " + po.names[0] + " " + po.names[1] + " shelf " + mathlib.ml_shelf_len(shelf) + " back " + bk.length + " " + bk[0].name);
    }

    // numbers as the other clients print them: 11, not 11.0
    static String fmt(double d) {
        return d == Math.rint(d) ? Long.toString((long) d) : Double.toString(d);
    }
}
