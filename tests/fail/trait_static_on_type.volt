// a static fn on the trait type itself: no value picks the member
trait shape { fn kind_name(static this) -> str; }
struct circle { r: f64; }
attach shape -> circle { fn kind_name(static this) -> str { return "circle"; } }
fn main() -> void { val n = shape::kind_name(); }
// error: a static fn through shape needs a value to pick the type: v.kind_name(), or circle::kind_name()
