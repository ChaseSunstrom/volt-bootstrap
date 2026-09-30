// C++ calls the Volt library through voltc bindings --lang cpp
#include <cstdio>
#include "mathlib.hpp"

int main() {
    std::printf("add %d\n", mathlib::ml_add(2, 3));
    mathlib::vec2 a{1, 2}, b{3, 4};
    std::printf("dot %g\n", mathlib::ml_dot(a, b));
    mathlib::ml_scale(&a, 2);
    std::printf("scale %g %g\n", a.x, a.y);
    std::printf("len %zu\n", mathlib::ml_len(mathlib::str("hello")));
    std::printf("next %d\n", (int)mathlib::ml_next(mathlib::color::GREEN));
    auto r = mathlib::ml_sqrt(9);
    std::printf("sqrt %g %d\n", r.value, r.error == 0);
    r = mathlib::ml_sqrt(-1);
    std::printf("error %s\n", r.error == mathlib::math_error::NEGATIVE ? "negative" : "?");
}
