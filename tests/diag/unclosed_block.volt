// an unclosed '{' is reported at the brace, guessed from the indentation, and the items after it
// still parse
fn sign(x: i32) -> i32 {
    if (x > 0) {
        return 1;
    return 0;
}

fn broken() -> i32 {
    return 2 +;
}

fn tail() -> void {
    val y = 1;
