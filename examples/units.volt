// One comptime call writes a whole conversion layer: every unit to every other, attached to f64
// (a type Volt owns, not this program), plus a lookup by name. With the 40 units below that's
// 40 × 39 = 1560 fns like `attach fn km_to_mi(this: f64) -> f64`, and a convert() whose body is
// 1560 branches: `voltc expand examples/units.volt` lists each fn it declared (tests/golden.rs
// counts them).
use std::io;

comptime fn conversions(names: str[], meters: f64[]) -> void {
    for (i) in 0..names.len {
        for (j) in 0..names.len {
            if (i != j) {
                attach fn (names[i] + "_to_" + names[j])(this: f64) -> f64 {
                    return this * (meters[i] / meters[j]);
                }
            }
        }
    }
    // convert(v, "km", "mi"): the same, picked by name at run time
    fn convert(v: f64, from: str, to: str) -> f64? {
        comptime for (i) in 0..names.len {
            comptime for (j) in 0..names.len {
                comptime if (i != j) {
                    if (from == names[i] && to == names[j]) {
                        return @field(v, names[i] + "_to_" + names[j])();
                    }
                }
            }
        }
        return null;
    }
}

comptime conversions(
    {
        "nm", "um", "mm", "cm", "dm", "m", "dam", "hm", "km", "Mm",
        "inch", "ft", "yd", "mi", "nmi", "league", "fathom", "chain", "furlong", "rod",
        "link", "hand", "span", "cubit", "pace", "mil", "thou", "point", "pica", "twip",
        "ly", "au", "pc", "smoot", "barleycorn", "shaku", "ri", "li", "verst", "arshin",
    },
    {
        1e-9, 1e-6, 1e-3, 1e-2, 1e-1, 1.0, 10.0, 100.0, 1000.0, 1e6,
        0.0254, 0.3048, 0.9144, 1609.344, 1852.0, 4828.032, 1.8288, 20.1168, 201.168, 5.0292,
        0.201168, 0.1016, 0.2286, 0.4572, 0.762, 0.0000254, 0.0000254, 0.000352778, 0.004233333, 0.0000176389,
        9.4607e15, 1.495978707e11, 3.0857e16, 1.7018, 0.008467, 0.30303, 3927.27, 500.0, 1066.8, 0.7112,
    },
);

fn main() -> void {
    val d: f64 = 42.195;
    std::println("{} km is {} mi", d, @cast<i64>(d.km_to_mi() + 0.5));
    std::println("364.4 smoots is {} m", @cast<i64>(364.4.smoot_to_m()));
    std::println("{}", @cast<i64>((convert(1.0, "mi", "ft") ?? 0.0) + 0.5));
    std::println("{}", convert(1.0, "mi", "parsec") == null);
}
// expect: 42.195 km is 26 mi
// expect: 364.4 smoots is 620 m
// expect: 5280
// expect: true
