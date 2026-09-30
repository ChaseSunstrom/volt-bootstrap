use std::io;
// Volt embeds Python through its C API (Python.h: --cc flags from python3-config)
use { "Python.h" } as py;

fn main() -> void {
    py::Py_Initialize();
    py::PyRun_SimpleStringFlags("print('python', 6 * 7)", null);
    py::Py_Finalize();
}
