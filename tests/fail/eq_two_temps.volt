// == with a type's eq takes one side by reference: two temporaries need one stored first
@attributes([@derive(eq)])
struct point {
    x: i32;
}

fn make(x: i32) -> point {
    return { x: x };
}

fn main() -> void {
    val same = make(1) == make(1);
}
// error: == on two temporary points: store one in a variable first
