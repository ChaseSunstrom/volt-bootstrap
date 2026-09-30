// an error inside a template instance says which instance and where it was used
<T: type>
fn twice(x: T) -> T {
    return x + x;
}

fn main() -> void {
    val n = twice(2);
    val b = twice(true);
}
