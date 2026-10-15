// a conversion into a trait nothing attaches: it has no values
trait plugin { fn f(this) -> i32; }
struct s { n: i32; }
fn main() -> void {
    val v: s = { n: 1 };
    val p = v as plugin;
}
// error: no type attaches plugin, so it has no values
