// error: 'this' was moved earlier
struct big { x: std::string; }
attach fn twice(this: big) -> big {
    val a = this;
    return this;
}
fn main() -> void {}
