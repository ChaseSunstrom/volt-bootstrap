<T: type>
type list = std::vec<T>;

fn main() -> void {
    var xs: list<i32, i32> = {};
}
// error: too many generic arguments (expected 1)
