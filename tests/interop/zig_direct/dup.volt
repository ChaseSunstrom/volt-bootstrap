use std::io;
// a limit: impl.zig under two names, used through both, is two libraries defining its export fns
// (zig_ext_add, zig_ext_total) twice; the link fails (interop.rs checks that it does)
use { "kinds.zig" } as kd;
use { "impl.zig" } as a;
use { "impl.zig" } as b;

fn main() -> void {
    val c = kd::ctxCreate(2);
    std::println("dup {} {} {} {}", kd::zig_ext_total(&c), kd::zig_ext_add(1, 2), a::twice(1), b::twice(2));
    kd::ctxDestroy(&c);
}
