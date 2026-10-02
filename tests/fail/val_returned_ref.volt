// A reference a fn returns points where its argument did: writing through it changes that.

struct point {
    x: i32;
}

fn id(r: i32&) -> i32& {
    return r;
}

fn again(r: i32&) -> i32& {
    return id(r);
}

attach fn x_of(this: point&) -> i32& {
    return &this.x;
}

fn set(r: i32&) -> void {
    *r = 1;
}

fn direct() -> void {
    val a = 0;
    *id(&a) = 1;
}

fn through_local() -> void {
    val b = 0;
    val r = id(&b);
    *r = 1;
}

fn method() -> void {
    val p: point = { x: 0 };
    *p.x_of() = 1;
}

fn nested() -> void {
    val c = 0;
    *id(id(&c)) = 1;
}

fn passed_on() -> void {
    val d = 0;
    set(id(&d));
}

fn returned_call() -> void {
    val e = 0;
    *again(&e) = 1;
}

fn param(f: i32&) -> void {
    *id(f) = 2;
}

fn captured() -> void {
    val h = 0;
    val r = id(&h);
    val c = |r| () {
        *r = 1;
    };
    c();
}

async fn aid(r: i32&) -> i32& {
    return r;
}

fn async_run() -> void {
    val k = 0;
    *aid(&k) = 1;
}

fn lends_to_param() -> void {
    val g = 0;
    param(&g);
}

fn main() -> void {}
// error: 'a' is a val, and it's changed through what id returns: declare it with var
// error: 'b' is a val, and it's changed through what id returns: declare it with var
// error: 'p' is a val, and it's changed through what x_of returns: declare it with var
// error: 'c' is a val, and it's changed through what id returns: declare it with var
// error: 'd' is a val, and it's changed through what id returns: declare it with var
// error: 'e' is a val, and it's changed through what again returns: declare it with var
// error: 'g' is a val, and param changes it (through f): declare it with var
// error: 'h' is a val, and it's changed through what id returns: declare it with var
// error: 'k' is a val, and it's changed through what aid returns: declare it with var
