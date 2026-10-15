// a method taking this by value can't be called through a reference: that would move the value
// out of the reference, which still owns it (copy it first: (copy *r).consume())
struct res {
    s: std::string;
}

attach fn consume(this: res) -> usize {
    return this.s.len();
}

fn f(r: res&) -> usize {
    return r.consume();
}

fn main() -> void {}
// error: can't move a res out of a field, element or reference; copy it instead: copy x
