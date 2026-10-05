// an owned base behind a reference can't move into an update; ..copy this copies it
struct named { name: str; n: i32 = 0; }
attach fn delete(this: named&) -> void {}
attach fn renumbered(this: named&, n: i32) -> named { return { ..this, n }; }
fn main() -> void {}
// error: can't move a named out of a field, element or reference; copy it instead
