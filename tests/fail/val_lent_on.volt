// the write happens two calls down, and through a field
struct pair {
    a: i32 = 0;
    b: i32 = 0;
}

fn set_b(r: i32&, v: i32) -> void {
    *r = v;
}

fn fill(p: pair&) -> void {
    set_b(&p.b, 7);
}

fn main() -> void {
    val p: pair = {};
    fill(&p);
}
// error: 'p' is a val, and fill changes it (through p): declare it with var
