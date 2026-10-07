// nlohmann::json, as installed: basic_json is a class template with private state, so Volt holds
// it by handle (json, the header's alias for its instance, names it) and works its members out per
// use; and what else maps, through its inline ABI namespace
use std::io;
use { "nlohmann/json.hpp" } as cpp;

fn main() -> void {
    std::println("{} {}", cpp::nlohmann::detail::op_lt(cpp::nlohmann::detail::value_t::null_, cpp::nlohmann::detail::value_t::string), @cast<i32>(cpp::nlohmann::detail::value_t::string));
    val empty: cpp::nlohmann::json = {};
    val doc = cpp::nlohmann::json::parse("{\"a\": 3, \"b\": [1, 2]}");
    std::println("{} {} {}", empty.is_null(), doc.size(), doc.dump());
}
