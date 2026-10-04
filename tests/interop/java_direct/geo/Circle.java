package geo;

public class Circle implements Shape {
    private final double r;
    public Color color = Color.RED;

    public Circle(double r) {
        this.r = r;
    }

    public double area() {
        return 3 * r * r;
    }

    public String name() {
        return "circle";
    }
}
