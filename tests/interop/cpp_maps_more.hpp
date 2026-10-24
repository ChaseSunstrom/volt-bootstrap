// std::map / std::unordered_map parameters beyond the default order and plain parts
// (cpp_maps_more.volt): another order (std::greater, a comparator class), a mutable map& whose
// changes go back to the Volt map, enum keys and values, values of a class Volt lays out
#pragma once
#include <functional>
#include <map>
#include <string>
#include <unordered_map>

namespace mm {
enum class Color { RED, GREEN, BLUE };
struct pt { int x; int y; };
struct by_len {
    bool operator()(const std::string &a, const std::string &b) const { return a.size() < b.size(); }
};

inline int first_desc(const std::map<int, int, std::greater<int>> &m) { return m.begin()->first; }
inline std::string shortest(const std::map<std::string, int, by_len> &m) { return m.begin()->first; }
inline int bump(std::map<std::string, int> &m) {
    m["new"] = 1;
    for (auto &e : m) {
        e.second += 10;
    }
    return (int)m.size();
}
inline void drop_odd(std::unordered_map<int, int> &m) {
    for (auto i = m.begin(); i != m.end();) {
        if (i->first % 2 != 0) {
            i = m.erase(i);
        } else {
            ++i;
        }
    }
}
inline int reds(const std::map<Color, int> &m) {
    auto it = m.find(Color::RED);
    return it == m.end() ? -1 : it->second;
}
inline void paint(std::map<int, Color> &m) { m[9] = Color::BLUE; }
inline int xsum(const std::map<int, pt> &m) {
    int s = 0;
    for (auto &e : m) {
        s += e.second.x;
    }
    return s;
}
}
