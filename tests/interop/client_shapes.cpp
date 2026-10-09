// C++ calls shapelib (voltc bindings --lang cpp): a generic's instances as overloads, a struct held
// by a class with methods, owned values passed in, a Volt trait as an abstract class both ways,
// closures taking and giving text and handles, and closures given back as std::function
#include <array>
#include <cstdio>
#include <memory>
#include <vector>
#include "shapelib.hpp"

struct circle : shapelib::shape {
    double r;
    explicit circle(double r) : r(r) {}
    ~circle() override { std::printf("circle gone\n"); }
    double area() override { return 3 * r * r; }
    std::string name() override { return "circle"; }
    void grow(double by) override { r += by; }
};

// lists (std::vector both ways), containers of text and handles, std::optional text and handles
static void lists() {
    std::vector<shapelib::account> ab;
    ab.push_back(shapelib::account::open("ann"));
    ab[0].deposit(5);
    ab.push_back(shapelib::account::open("bobby"));
    ab[1].deposit(9);
    auto os = shapelib::owners(ab);
    std::printf("owners %zu %s %s\n", os.size(), os[0].c_str(), os[1].c_str());
    std::printf("richest %lld", (long long)shapelib::richest(ab));
    std::printf(" after %lld %lld\n", (long long)ab[0].get_(), (long long)ab[1].get_());
    std::vector<std::string> names{"cy", "dee"};
    auto opened = shapelib::open_all(names);
    std::printf("opened %zu %s\n", opened.size(), opened[1].owner().c_str());
    opened.clear();
    auto sq = shapelib::squares_upto(4);
    std::printf("squares %zu %lld sum %lld\n", sq.size(), (long long)sq[3], (long long)shapelib::sum_all(sq));
    std::vector<std::string> parts{"a", "b", "c"};
    std::printf("joined %s total %lld\n", shapelib::joined(parts, "-").c_str(), (long long)shapelib::total_len(parts));
    std::printf("%s; %s\n", shapelib::greeting(shapelib::str("ann")).c_str(), shapelib::greeting(std::nullopt).c_str());
    auto n1 = shapelib::nickname(ab[0]);
    auto n2 = shapelib::nickname(ab[1]);
    std::printf("nick %d %s %d\n", n1.has_value(), n1->c_str(), n2.has_value());
    auto c = shapelib::open_if("eve", true);
    auto d = shapelib::open_if("x", false);
    std::printf("open_if %d %d\n", c.has_value(), !d.has_value());
    long long c1 = shapelib::close_if(std::move(c));
    std::printf("close_if %lld %lld\n", c1, (long long)shapelib::close_if(std::nullopt));
    std::printf("close_all %lld\n", (long long)shapelib::close_all(std::move(ab)));
    std::vector<shapelib::opt_i64> some{{1, true}, {0, false}, {3, true}};
    std::printf("some %lld\n", (long long)shapelib::count_some(some));
    std::vector<int64_t> r1{1, 2}, r2{3};
    shapelib::slice_i64 rr[] = {r1, r2};
    std::printf("rows %lld\n", (long long)shapelib::total_rows(rr));
    std::array<int64_t, 3> rot = shapelib::rotated({11, 12, 13});
    std::array<double, 2> sw = shapelib::swapped({1.5, 2.5});
    std::array<uint8_t, 3> bu = shapelib::bumped({1, 2, 3});
    std::printf("arrays %lld %lld %lld %g %g %d %d %d\n", (long long)rot[0], (long long)rot[1], (long long)rot[2], sw[0], sw[1], bu[0], bu[1], bu[2]);
    struct tg : shapelib::tagged {
        int32_t type() override { return 1; }
        int32_t from(int32_t x) override { return x + 1; }
        int32_t int_() override { return 2; }
        int32_t close() override { return 3; }
    } t0;
    auto tv = shapelib::make_tagged(5);
    std::printf("tagged %d %d %d %d %d %d\n", shapelib::tagged_sum(t0), tv->type(), tv->from(4), tv->int_(), tv->close(), shapelib::tagged_sum(*tv));
    std::printf("lists closed %d\n", shapelib::closed_accounts());
}

int main() {
    std::vector<int32_t> xs{3, 9, 4};
    std::vector<double> ys{1.5, 0.5};
    std::printf("biggest %d %g\n", shapelib::biggest(xs), shapelib::biggest(ys));
    auto a = shapelib::account::open("ann");
    a.deposit(250);
    a.rename("bea");
    long long n = a.deposit(50);
    std::printf("account %s %lld\n", a.owner().c_str(), n);
    n = shapelib::visit(a, [](shapelib::account &b) { return b.deposit(1); });
    std::printf("visit %lld get %lld\n", n, (long long)a.get_());
    n = shapelib::close_account(std::move(a));
    std::printf("closed %lld %d\n", n, shapelib::closed_accounts());
    circle c(1);
    std::printf("%s\n", shapelib::describe(c).c_str());
    double g = shapelib::grow_twice(std::make_unique<circle>(1));
    std::printf("grown %g\n", g);
    auto sq = shapelib::make_square(2);
    sq->grow(1);
    std::printf("%s %g %s\n", sq->name().c_str(), sq->area(), shapelib::describe(*sq).c_str());
    std::printf("%s\n", shapelib::shout([](std::string s) { return s + "!"; }, "hey").c_str());
    auto twice = [](int32_t x) { return x > 5 ? shapelib::bank_error_or_i32{shapelib::bank_error::OVERDRAWN, 0} : shapelib::bank_error_or_i32{0, x * 2}; };
    std::printf("try %d", shapelib::try_twice(twice, 1));
    try {
        shapelib::try_twice(twice, 4);
    } catch (const shapelib::error &e) {
        std::printf(" %s\n", e.what());
    }
    n = shapelib::opened_by([](shapelib::str owner) {
        auto b = shapelib::account::open(owner);
        b.deposit(7);
        return b;
    });
    std::printf("opened %lld\n", n);
    std::printf("closed %d\n", shapelib::closed_accounts());
    auto d = shapelib::doubler();
    auto hi = shapelib::greeter();
    std::printf("%d %s\n", d(21), hi("volt").c_str());
    lists();
}
