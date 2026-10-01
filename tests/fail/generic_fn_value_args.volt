<T: type>
fn id(x: T) -> T { return x; }
fn main() -> void {
    val f = id<i32, i64>;
}
// error: too many generic arguments for 'id'
