// ledger.hpp: C++ for the C++ interop page's standard library example (site/.../interop/cpp.md)
#pragma once
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace ledger {

struct Money {
    long cents;
    Money operator+(const Money& o) const { return {cents + o.cents}; }
    bool operator<(const Money& o) const { return cents < o.cents; }
};

inline long cents(std::string_view s) {
    std::size_t dot = s.find('.');
    if (dot == std::string_view::npos || dot + 3 != s.size()) {
        throw std::invalid_argument("expected units.cents, not '" + std::string(s) + "'");
    }
    return std::stol(std::string(s.substr(0, dot))) * 100 + std::stol(std::string(s.substr(dot + 1)));
}

inline Money parse(std::string_view s) { return {cents(s)}; }

inline std::string format(Money m) { return std::to_string(m.cents / 100) + "." + (m.cents % 100 < 10 ? "0" : "") + std::to_string(m.cents % 100); }

inline std::vector<long> running(const std::vector<long>& xs) {
    std::vector<long> out;
    long total = 0;
    for (long x : xs) out.push_back(total += x);
    return out;
}

class Book {
public:
    explicit Book(int id) : id(id) {}
    int id;
};
inline std::unique_ptr<Book> open_book(int id) { return std::make_unique<Book>(id); }

}  // namespace ledger
