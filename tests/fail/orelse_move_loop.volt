// a ?? fallback declared outside a loop can move on any pass, so it needs a new value before the next
fn find(i: i32) -> std::string? {
    return null;
}

fn main() -> void {
    val spare = std::string::from("spare");
    for (i) in 0..3 {
        val s = find(i) ?? spare;
    }
}
// error: 'spare' is moved inside a loop and has no new value before the next pass
