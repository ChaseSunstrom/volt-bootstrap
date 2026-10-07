// a std::function field keeps its closure: one capturing by reference is an error at set_
use { "fields.hpp" } as cpp;

fn main() -> void {
    var d: cpp::fl::Device = {};
    var k = 2;
    d.set_scale(|k&| (x: i32) -> i32 { return x * k; });
}
