package geo;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

// what crosses beyond the import's own classes: collections (copies), generic methods, and classes
// the import doesn't have (an opaque object)
public final class Generic {
    private Generic() {
    }

    public static int total(List<Integer> xs) {
        int t = 0;
        for (int x : xs) {
            t += x;
        }
        return t;
    }

    public static List<String> words(String s) {
        List<String> out = new ArrayList<>();
        for (String w : s.trim().split("\\s+")) {
            out.add(w);
        }
        return out;
    }

    public static Set<String> unique(List<String> xs) {
        return new TreeSet<>(xs);
    }

    public static Map<String, Integer> lengths(List<String> xs) {
        Map<String, Integer> out = new TreeMap<>();
        for (String x : xs) {
            out.put(x, x.length());
        }
        return out;
    }

    public static int sumValues(Map<String, Integer> m) {
        int t = 0;
        for (int v : m.values()) {
            t += v;
        }
        return t;
    }

    public static double farthest(List<Point> ps) {
        double best = 0;
        for (Point p : ps) {
            best = Math.max(best, p.dist(new Point()));
        }
        return best;
    }

    public static List<Color> cycle(List<Color> cs) {
        List<Color> out = new ArrayList<>();
        for (Color c : cs) {
            out.add(c.next());
        }
        return out;
    }

    public static <T> T first(List<T> xs) {
        return xs.get(0);
    }

    public static <T extends Comparable<T>> T max(T a, T b) {
        return a.compareTo(b) >= 0 ? a : b;
    }

    public static Duration minutes(long n) {
        return Duration.ofMinutes(n);
    }

    public static long seconds(Duration d) {
        return d.getSeconds();
    }

    public static Object boxed(int n) {
        return Integer.valueOf(n);
    }
}
