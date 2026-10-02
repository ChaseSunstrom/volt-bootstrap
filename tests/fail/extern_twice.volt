// a program that declares one C function twice, with different signatures
extern "C" fn puts(s: cstr) -> i32;

namespace other {
    extern "C" fn puts(s: u8*) -> i32;
}

fn main() -> void {
    puts("a");
    other::puts(@cast<u8*>("b".ptr));
}
// error: C function 'volt_ext_puts' is declared twice
