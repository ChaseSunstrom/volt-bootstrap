// a template taking a Volt std::string as S& that throws, called in its plain form, stops the
// program (a try_ form's error is in cpp_params.volt)
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var t = std::string::from("a");
    cpp::pr::gs::grow(&t, -1);
    std::println("not reached {}", t);
}
