// a generic closure can't be kept in a std::func (the fn type gives its parameters)
fn make() -> std::func<fn(i32) -> i32> {
    return || <T: type>(x: T) -> T { return x + x; };
}

fn main() -> void {
    val f = make();
}
// error: a generic closure can't be kept in a std::func<fn(i32) -> i32>
