// a static fn on a trait nothing attaches, through the type: no value, and no member to suggest
trait plugin { fn label(static this) -> str; }
fn main() -> void { val n = plugin::label(); }
// error: a static fn through plugin needs a value to pick the type: v.label()
