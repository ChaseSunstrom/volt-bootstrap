// C++ with standard library types, operators, rvalue references and exceptions in its signatures
// (tests/interop/cpp_std.volt imports it)
#pragma once
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace lib {

inline std::string greet(const std::string& name) { return "hello, " + name; }
inline std::size_t count(std::string_view s, char c) {
    std::size_t n = 0;
    for (char x : s) n += x == c;
    return n;
}
inline std::string_view first_word(std::string_view s) { return s.substr(0, s.find(' ')); }
inline double sum(const std::vector<double>& xs) {
    double t = 0;
    for (double x : xs) t += x;
    return t;
}
inline std::vector<int> range(int n) {
    std::vector<int> v;
    for (int i = 0; i < n; i++) v.push_back(i * i);
    return v;
}
inline int parse(const std::string& s) {
    std::size_t used = 0;
    int v = std::stoi(s, &used);
    if (used != s.size()) throw std::invalid_argument("trailing characters in '" + s + "'");
    return v;
}
inline void must_be_positive(int x) noexcept(false) {
    if (x <= 0) throw std::out_of_range("not positive");
}

struct Vec2 {
    double x, y;
    Vec2 operator+(const Vec2& o) const { return {x + o.x, y + o.y}; }
    Vec2 operator-() const { return {-x, -y}; }
    bool operator==(const Vec2& o) const { return x == o.x && y == o.y; }
    double operator[](int i) const { return i == 0 ? x : y; }
    Vec2& operator+=(const Vec2& o) { x += o.x; y += o.y; return *this; }
};
inline Vec2 operator*(const Vec2& v, double k) { return {v.x * k, v.y * k}; }

class Node {
public:
    explicit Node(int v) : value(v) {}
    int value;
};
inline std::unique_ptr<Node> make_node(int v) { return std::make_unique<Node>(v); }
inline int take_node(std::unique_ptr<Node> n) { return n->value * 10; }
inline std::shared_ptr<Node> share_node(int v) { return std::make_shared<Node>(v); }
inline long uses(const std::shared_ptr<Node>& n) { return n.use_count(); }

// (its strings are behind the vector's pointer: Volt moves objects by copying their bytes, which a
// std::string held by value doesn't survive)
class Buffer {
public:
    Buffer() {}
    void append(std::string&& s) { parts.push_back(std::move(s)); }
    std::string str() const {
        std::string t;
        for (const auto& p : parts) t += p;
        return t;
    }
    std::size_t size() const noexcept { return str().size(); }

private:
    std::vector<std::string> parts;
};

}  // namespace lib
