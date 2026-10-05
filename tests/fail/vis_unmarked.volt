// flags: --pkg vis=tests/pkgs/vis
// a package's items that aren't marked public can't be named from outside it (each fn below is
// checked on its own, so each reports its error)

fn call_fn() -> i32 {
    return vis::helper();
}

fn read_global() -> i32 {
    return vis::HIDDEN;
}

fn call_method() -> i32 {
    val p: vis::point = { x: 1, y: 2 };
    return p.bonus();
}

fn main() -> void {}
// error: 'helper' isn't public in package vis
// error: 'HIDDEN' isn't public in package vis
// error: 'bonus' isn't public in package vis
