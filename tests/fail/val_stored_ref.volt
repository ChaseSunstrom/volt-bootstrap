// A reference stored in a struct, array or tuple, passed or returned inside one, or assigned to a
// reference later, still points at what can't change: writing through it is an error.

struct holder {
    r: i32&;
}

fn poke(h: holder) -> void {
    *h.r = 1;
}

fn wrap(r: i32&) -> holder {
    return { r: r };
}

fn pick(r: i32&) -> !(i32&) {
    return r;
}

fn in_struct() -> void {
    val a = 0;
    val h: holder = { r: &a };
    *h.r = 1;
}

fn in_array() -> void {
    val b = 0;
    val c = 0;
    val rs: i32&[2] = { &b, &c };
    *rs[0] = 1;
}

fn passed_in_struct() -> void {
    val d = 0;
    poke({ r: &d });
}

fn in_tuple() -> void {
    val e = 0;
    val t = (&e, 2);
    *t.0 = 1;
}

fn reseated() -> void {
    val f = 0;
    var g = 0;
    var r: i32& = &g;
    r = &f;
    *r = 1;
}

fn returned_in_struct() -> void {
    val h = 0;
    *wrap(&h).r = 1;
}

fn returned_in_error_union() -> !void {
    val k = 0;
    val p = try pick(&k);
    *p = 1;
}

fn field_reseated() -> void {
    val m = 0;
    var n = 0;
    var h: holder = { r: &n };
    h.r = &m;
    *h.r = 1;
}

fn looped() -> void {
    val p = 0;
    val rs: i32&[1] = { &p };
    for (r) in rs {
        *r = 1;
    }
}

fn looped_slice() -> void {
    val q = 0;
    val rs: i32&[1] = { &q };
    for (r) in rs[..] {
        *r = 1;
    }
}

error pick_error {
    NONE,
}

fn pick_e(r: i32&) -> pick_error!(i32&) {
    return r;
}

fn widened(r: i32&) -> !(i32&) {
    return pick_e(r);
}

fn converted() -> !void {
    val w = 0;
    val p = try widened(&w);
    *p = 1;
}

fn main() -> void {}
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: 'd' is a val, and poke changes it (through h): declare it with var
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: 'h' is a val, and it's changed through what wrap returns: declare it with var
// error: 'k' is a val, and it's changed through what pick returns: declare it with var
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: can't assign through this; it reaches a val (or a parameter without var)
// error: 'w' is a val, and it's changed through what widened returns: declare it with var
