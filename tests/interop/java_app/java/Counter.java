// a Java class the Volt program in src/ calls through interop/java
public class Counter {
    private int count;
    private final String name;

    public Counter(String name, int start) {
        this.name = name;
        this.count = start;
    }

    public int bump(int by) {
        count += by;
        return count;
    }

    public double half() {
        return count / 2.0;
    }

    @Override
    public String toString() {
        return name + "=" + count;
    }

    public static int add(int a, int b) {
        return a + b;
    }

    public static String greet(String who, boolean loud) {
        String s = "hello, " + who;
        return loud ? s.toUpperCase() : s;
    }

    public static int divide(int a, int b) {
        return a / b;
    }
}
