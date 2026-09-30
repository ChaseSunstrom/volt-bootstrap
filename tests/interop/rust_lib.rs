// a Rust static library Volt calls (and that calls Volt back), both through the C ABI
#[no_mangle]
pub extern "C" fn rs_triple(x: i32) -> i32 {
    x * 3
}

#[no_mangle]
pub extern "C" fn rs_apply(f: extern "C" fn(i32) -> i32, x: i32) -> i32 {
    f(x)
}
