// x.try_m(...) where the class has neither try_m nor m: the error is m's, in clang's words
use { "params.hpp" } as cpp;
fn main() -> void {
    val k = cpp::pr::pu::Keep<i32>::new(1);
    val n = k.try_nothing(2) catch |e| { return; };
}
