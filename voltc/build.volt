// voltc's build file: the bootstrap step (see tools/bootstrap.volt)
fn main() -> void {
    bolt::link_c("LLVM"); // the compiler's LLVM backend (the llvm-c API)
    bolt::link_c("clang"); // C struct layouts and C++ import (libclang)
    bolt::exe("bootstrap", "tools/bootstrap.volt");
    bolt::step("bootstrap");
    bolt::run("bootstrap", "bootstrap");
}
