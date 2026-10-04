package geo;

// Ordinary Java: nothing in it is written for Volt
public class Point {
    public double x, y;
    public static final int DIMS = 2;
    public static int made = 0;

    public Point(double x, double y) {
        this.x = x;
        this.y = y;
        made++;
    }

    public Point() {
        this(0, 0);
    }

    public double dist(Point o) {
        return Math.hypot(x - o.x, y - o.y);
    }

    public Point scaled(double k) {
        return new Point(x * k, y * k);
    }

    public void scale(double k) {
        x *= k;
        y *= k;
    }

    public static Point parse(String s) throws NumberFormatException {
        String[] p = s.split(",");
        return new Point(Double.parseDouble(p[0].trim()), Double.parseDouble(p[1].trim()));
    }

    @Override
    public String toString() {
        return "(" + x + ", " + y + ")";
    }
}
