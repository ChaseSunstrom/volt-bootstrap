// an if without braces is a value: it needs an else
fn main() -> void {
    val x = if (true) 1;
}
// error: expected 'else' (an if without { } is a value: if (c) a else b), found ';'
