struct r { n: i32; }
attach fn delete(this: r&) -> void {}
<T: type> fn plain(v: T) -> void {
    comptime if (!@typeinfo(T).is_pod) { @compile_error("only plain values"); }
}
fn main() -> void { val x: r = { n: 1 }; plain(move x); }
// error: only plain values
