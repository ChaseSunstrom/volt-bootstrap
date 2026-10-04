package geo;

public enum Color {
    RED("r"), GREEN("g"), BLUE("b");

    public final String code;

    Color(String code) {
        this.code = code;
    }

    public Color next() {
        return values()[(ordinal() + 1) % 3];
    }

    public String lower() {
        return name().toLowerCase();
    }
}
