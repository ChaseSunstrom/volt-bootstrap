// nlohmann::json, as installed: what maps of it (its class templates hold private state, so
// basic_json itself isn't one Volt can lay out), through its inline ABI namespace
use std::io;
use { "nlohmann/json.hpp" } as cpp;

fn main() -> void {
    std::println("{} {}", cpp::nlohmann::detail::op_lt(cpp::nlohmann::detail::value_t::null_, cpp::nlohmann::detail::value_t::string), @cast<i32>(cpp::nlohmann::detail::value_t::string));
}
