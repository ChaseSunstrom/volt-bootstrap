// a class template's operator T() is to_T() and its operator bool() to_bool(), on every instance
use std::io;
use { "cpp_template_conv.hpp" } as cpp;
fn main() -> void {
    val i = cpp::tc::box_int(7);
    val z = cpp::tc::box_int(0);
    val d = cpp::tc::box_double(2.5);
    std::println("int {} {} {}", i.to_T(), i.to_bool(), z.to_bool());
    std::println("double {} {}", d.to_T(), d.to_bool());
}
