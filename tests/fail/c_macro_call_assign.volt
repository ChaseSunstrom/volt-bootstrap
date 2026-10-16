// a C macro read as a value has no place: it can't be assigned
use { "../run/c_macro_call.h" } as c;
fn main() -> void {
    c::first_counter = null;
}
// error: can't assign to this; it's a temporary value
