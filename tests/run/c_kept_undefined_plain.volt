// a header kept out of Volt's C whose functions nothing defines: the one called directly (no wrapper)
// panics naming it, as c_kept_undefined.volt's wrapped one does (T-0320)
// os: linux
// (only ELF linkers take a weak reference to what nothing defines and leave it null: Mach-O's refuses
// it, and COFF's wrapper callee is a plain reference)
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
