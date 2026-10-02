type a = b;
type b = a;

fn main() -> void {
    val x: a = 1;
}
// error: type 'a' is defined in terms of itself
