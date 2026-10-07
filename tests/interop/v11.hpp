// C++11: constexpr, trailing return types, nullptr, enum class
#pragma once
namespace v11 {
constexpr int sq(int x) { return x * x; }
inline auto add(int a, int b) -> int { return a + b; }
enum class color : unsigned char { red = 1, green = 2 };
inline int code(color c) { return c == color::green && nullptr == nullptr ? 2 : 1; }
}
