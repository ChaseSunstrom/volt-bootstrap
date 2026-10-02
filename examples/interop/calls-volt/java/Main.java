// Java calls the Volt library greet through its class (bindings/greet.java, over the FFM API of JDK
// 22 and later): owned text comes back as a String, an export struct is AutoCloseable
public class Main {
    public static void main(String[] args) {
        System.out.println("add " + greet.add(2, 3));
        System.out.println(greet.hello("volt"));
        try (var c = new greet.tally("clicks")) {
            c.add(1);
            long n = c.add(2);
            System.out.println(c.name() + " " + n);
        }
    }
}
