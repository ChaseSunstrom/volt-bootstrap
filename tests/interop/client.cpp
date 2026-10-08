// C++ calls the Volt library through voltc bindings --lang cpp: errors are thrown as mathlib::error,
// owned text comes back as std::string, an export struct is a class that frees itself
#include <cstdio>
#include <vector>
#include "mathlib.hpp"

int main() {
    std::printf("add %d\n", mathlib::ml_add(2, 3));
    mathlib::vec2 a{1, 2}, b{3, 4};
    std::printf("dot %g\n", mathlib::ml_dot(a, b));
    mathlib::ml_scale(a, 2);
    std::printf("scale %g %g\n", a.x, a.y);
    std::printf("len %zu\n", mathlib::ml_len("hello"));
    std::printf("clash %d\n", mathlib::ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14));
    std::printf("next %d\n", (int)mathlib::ml_next(mathlib::color::GREEN));
    std::printf("sqrt %g 1\n", mathlib::ml_sqrt(9));
    try {
        mathlib::ml_sqrt(-1);
    } catch (const mathlib::error &e) {
        std::printf("error %s\n", e.code == mathlib::math_error::NEGATIVE ? "negative" : "?");
    }
    std::printf("greet %s\n", mathlib::ml_greet("volt").c_str());
    std::printf("repeat %s\n", mathlib::ml_repeat("ab", 2).c_str());
    try {
        mathlib::ml_repeat("ab", -1);
    } catch (const mathlib::error &e) {
        std::printf("repeat %s\n", e.what() == std::string("NEGATIVE") ? "negative" : "?");
    }
    double xs[] = {1, 2, 3.5};
    std::printf("sum %g\n", mathlib::ml_sum(xs));
    std::vector<int32_t> ys{4, 5, 6};
    auto found = mathlib::ml_find(ys, 6);
    std::printf("find %zu %s\n", *found, mathlib::ml_find(ys, 9) ? "?" : "none");
    int total = 0;
    std::printf("each");
    mathlib::ml_each(ys, [&](int32_t x) {
        total += x;
        std::printf(" %d", x);
    });
    std::printf(" = %d\n", total);
    mathlib::counter c("clicks");
    c.add(2);
    std::printf("counter %s %lld\n", c.name().c_str(), (long long)c.add(3));
    try {
        c.take(9);
    } catch (const mathlib::error &e) {
        std::printf("take %s\n", e.code == mathlib::math_error::NEGATIVE ? "negative" : "?");
    }
}
