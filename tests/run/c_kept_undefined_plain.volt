// a header kept out of Volt's C whose functions nothing defines: the one called directly (no wrapper)
// panics naming it, as c_kept_undefined.volt's wrapped one does (T-0320)
use std::io;
@attributes([@standard("c89")])
use { "c_kept_undefined.h" } as old;

fn main() -> void {
    std::println("ok {}", old::kept_ok(2));
    std::println("{}", old::kept_missing(1));
}
// expect: ok 3
// exit: 101
// expect-stderr: panic: the C function kept_missing isn't defined anywhere (is its library linked?)
