// a std::string(&)[2] parameter takes a Volt std::string[2]&: another length is a type error, as a
// number array's is (no check when it runs)
use { "cpp_array_ref.hpp" } as cpp;
fn main() -> void {
    var ss: std::string[3] = { std::string::from("a"), std::string::from("b"), std::string::from("c") };
    cpp::ar::append(&ss, "x");
}
