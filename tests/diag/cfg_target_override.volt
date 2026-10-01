// flags: --pkg plat=tests/pkgs/plat --cfg os=windows --cfg arch=aarch64
// --cfg os=/arch= replace the host's values in every package, for checking (not building) another
// platform's code; these errors say what the program and the package see
fn main() -> void {
    comptime if (@cfg("os", "windows") && !@cfg("os", "linux") && @cfg("arch", "aarch64") && !@cfg("arch", "x86_64") && @cfg("pointer_bits", "64")) {
        @compile_error("the program sees windows on aarch64, and not the host");
    }
    plat::windows_check();
}
