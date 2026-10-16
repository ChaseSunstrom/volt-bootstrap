use std::io;
// a generic instance C# rejects (Shape isn't IComparable<Shape>) is an error at the call, with
// the C# compiler's reason
use { "Geo.cs", "Generic.cs" } as geo;

fn main() -> void {
    val a = geo::Shape::new();
    val b = geo::Shape::new();
    std::println("{}", geo::Gen::Max<geo::Shape>(a, b).Name());
}
