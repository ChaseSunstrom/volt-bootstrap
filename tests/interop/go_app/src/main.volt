use std::io;
// a Volt program using a Go library: bolt builds gomath/ (a Go module) into a static library and
// takes gomath.h from cgo
use { "gomath.h" } as go;

extern "C" fn free(p: void*) -> void;
extern "C" fn strlen(s: cstr) -> usize;

fn main() -> void {
    std::println("add {}", go::gm_add(2, 40));
    var xs: f64[3] = { 1.0, 2.0, 3.5 };
    std::println("sum {}", go::gm_sum(&xs[0], 3));
    // C.CString memory is the C heap's: free it
    val up = go::gm_upper(@cast<cstr>("volt\0".ptr)) ?? return;
    std::println("upper {}", @cast<str>(@slice(@cast<u8*>(up), strlen(up))));
    free(@cast<void*>(up));
    // a Go string is a pointer and a length
    val s = "one two  three";
    val g: go::GoString = { p: @cast<cstr>(s.ptr), n: @cast<isize>(s.len) };
    std::println("words {}", go::gm_words(g));
}
