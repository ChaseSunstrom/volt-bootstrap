// a ?? fallback that owns something counts as moved afterwards on both paths, as a move in one
// branch of an if does: it may be gone
fn find() -> std::string? {
    return null;
}

fn main() -> void {
    val spare = std::string::from("spare");
    val s = find() ?? spare;
    val n = spare.len();
}
// error: 'spare' was moved earlier
