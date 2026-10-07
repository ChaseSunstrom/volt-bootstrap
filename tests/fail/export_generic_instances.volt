// a generic export fn names the instances other languages call
<T: type>
export fn first(xs: T[..]) -> T {
    return xs[0];
}

fn main() -> void {}
// error: a generic export fn exports the instances it names
