# Python running Volt through libvoltvm's generated module (tests/embed.rs): a host function given as a
# ctypes callback, an export fn called through its address, and a compile error raised as vm_error
import ctypes
import sys

import voltvm


@ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)
def square(x):
    return x * x


with voltvm.volt_vm(sys.argv[1]) as vm:
    vm.define("host_square", ctypes.cast(square, ctypes.c_void_p).value)
    vm.load("calc.volt", """
extern "C" fn host_square(x: i64) -> i64;

export fn sum_squares(n: i64) -> i64 {
    var total: i64 = 0;
    for (i) in 1..n + 1 {
        total += host_square(i);
    }
    return total;
}
""")
    sum_squares = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(vm.find("sum_squares"))
    print("sum_squares", sum_squares(10))
    try:
        vm.load("bad.volt", "export fn broken() -> i32 { return nope; }\n")
    except voltvm.vm_error as e:
        print("error", e.name, vm.error().splitlines()[0])
