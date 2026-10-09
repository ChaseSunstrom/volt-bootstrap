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
    auto tg = mathlib::ml_tags_make();
    std::printf("tags %d %d %d %d", tg.from, tg.type, tg.self, tg.int_);
    tg.int_ = 5;
    std::printf(" %d\n", mathlib::ml_tags_sum(tg));
    int32_t bp = 7;
    double bq = 2.5;
    mathlib::ml_bump(&bp, bq);
    std::printf("bump %d %g\n", bp, bq);
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
    // structs with text, an array and a struct in them (in, out, in a slice, from a callback), one
    // with a pointer, E!T as a parameter
    mathlib::ml_label la{"ab", {1, 2, 3}, {7, 0}};
    std::printf("label %lld\n", (long long)mathlib::ml_label_len(la));
    mathlib::ml_label lb = mathlib::ml_label_of("ab", 3);
    std::printf("label_of %.*s %d %d %d %g\n", (int)lb.name.len, (const char *)lb.name.ptr, lb.sizes[0], lb.sizes[1], lb.sizes[2], lb.at.x);
    std::vector<mathlib::ml_label> ls{la, lb};
    std::printf("labels %lld\n", (long long)mathlib::ml_labels_len(ls));
    std::printf("holder %d\n", mathlib::ml_holder_k({nullptr, 3}));
    std::printf("or %g %g\n", mathlib::ml_or({0, 4.5}, 9.5), mathlib::ml_or({mathlib::math_error::NEGATIVE, 0}, 9.5));
    std::printf("ask %lld\n", (long long)mathlib::ml_ask([](int32_t k) { return mathlib::ml_label{"abc", {k, k, k}, {3, 0}}; }));
    mathlib::ml_relabel(lb, 4);
    std::printf("relabel %.*s %d %d %d\n", (int)lb.name.len, (const char *)lb.name.ptr, lb.sizes[0], lb.sizes[1], lb.sizes[2]);
    std::printf("count %lld\n", (long long)mathlib::ml_labels_count({la, lb}));
    std::printf("note %lld\n", (long long)mathlib::ml_note_len({"abc", 1, 3}));
    std::printf("or_label %lld %lld\n", (long long)mathlib::ml_or_label({0, la}), (long long)mathlib::ml_or_label({mathlib::math_error::NEGATIVE, {}}));
}
