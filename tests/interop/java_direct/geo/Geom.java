package geo;

import java.util.List;

public final class Geom {
    private Geom() {
    }

    public static int add(int a, int b) {
        return a + b;
    }

    public static long big(long a) {
        return a * 1000000000L;
    }

    public static String upper(String s) {
        return s.toUpperCase();
    }

    public static double sum(double[] xs) {
        double t = 0;
        for (double x : xs) {
            t += x;
        }
        return t;
    }

    // changes Volt's array: the change comes back
    public static void doubleAll(int[] xs) {
        for (int i = 0; i < xs.length; i++) {
            xs[i] *= 2;
        }
    }

    public static int[] squares(int n) {
        int[] out = new int[n];
        for (int i = 0; i < n; i++) {
            out[i] = (i + 1) * (i + 1);
        }
        return out;
    }

    public static String join(String[] parts, String sep) {
        return String.join(sep, parts);
    }

    public static String[] words(String s) {
        return s.trim().split("\\s+");
    }

    public static double totalArea(Shape a, Shape b) {
        return a.area() + b.area();
    }

    public static int parseInt(String s) throws NumberFormatException {
        return Integer.parseInt(s.trim());
    }

    public static int divide(int a, int b) {
        return a / b;
    }

    public static char first(String s) {
        return s.charAt(0);
    }

    public static boolean even(int x) {
        return x % 2 == 0;
    }

    public static Color mix(Color a, Color b) {
        return a == b ? a : Color.BLUE;
    }

    public static int count(int... xs) {
        return xs.length;
    }

    public static Point origin() {
        return null;
    }

    // Volt can't call these: they're listed in a comment of what bolt writes
    public static List<String> list() {
        return List.of();
    }

    public static <T> T ident(T x) {
        return x;
    }
}
