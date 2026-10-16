use std::io;
// impl.zig's library comes first, and only kinds.zig's shim needs it (for zig_ext_total): the
// linker still finds it
use { "impl.zig" } as im;
use { "kinds.zig" } as kd;

fn main() -> void {
    val c = kd::ctxCreate(2);
    std::println("order {}", kd::zig_ext_total(&c));
    kd::ctxDestroy(&c);
}
