// every struct copies field by field (copy x), so there's no copy derive; copy is a keyword
@attributes([@derive(eq, copy)])
struct point {
    x: i32;
}

fn main() -> void {}
// error: copy needs a value: copy x (a struct copies field by field; there's no copy derive)
