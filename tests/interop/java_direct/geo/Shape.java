package geo;

public interface Shape {
    double area();

    String name();

    default String describe() {
        return name() + " of area " + area();
    }
}
