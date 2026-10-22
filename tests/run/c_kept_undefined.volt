// a header kept out of Volt's C (its own standard, C89) whose functions nothing defines: the program
// links and runs, and calling one panics naming it, the one called through a wrapper (a long double)
// as the one called directly does (c_kept_undefined_plain.volt) (T-0320)
// os: linux
// (only ELF linkers take a weak reference to what nothing defines and leave it null: Mach-O's refuses
// it, and COFF's wrapper callee is a plain reference)
use std::io;
@attributes([@standard("c89")])
use { "c_kept_undefined.h" } as old;

fn main() -> void {
    std::println("ok {}", old::kept_ok(1));
    std::println("{}", old::kept_ld_missing(1.0));
}
// expect: ok 2
// exit: 101
// expect-stderr: panic: the C function kept_ld_missing isn't defined anywhere (is its library linked?)
