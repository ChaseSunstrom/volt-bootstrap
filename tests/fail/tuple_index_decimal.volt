// a tuple index is written in plain decimal: t.01 or t.0x1 would name element 1 in a way that reads
// like something else
fn main() -> void {
    val t = (1, 2);
    val x = t.01;
}
// error: a tuple index is a plain decimal number, like t.1
