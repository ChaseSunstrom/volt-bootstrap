// a type that attaches delete but not copy can't be copied: a copy of its bytes would be deleted
// twice (by the original and by the copy)
struct handle { fd: i32; }
attach fn delete(this: handle&) -> void {}

fn main() -> void {
    val a: handle = { fd: 3 };
    val b = copy a;
}
// error: can't copy handle: it attaches delete but not copy, so both copies would delete the same thing; attach fn copy(this: T&) -> T
