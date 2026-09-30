// dereferencing a null T* traps in debug builds
fn main() -> void {
    val p: i32* = null;
    val x = *p;
}
// exit: 101
