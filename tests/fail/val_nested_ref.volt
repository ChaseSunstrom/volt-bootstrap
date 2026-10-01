// a reference to a var reference that points at a val: the val still can't change
fn bump2(rr: i32* &) -> void {
    **rr += 1;
}

fn main() -> void {
    val x = 0;
    var r: i32* = &x;
    bump2(&r);
}
// error: 'x' is a val, and bump2 changes it (through rr): declare it with var
