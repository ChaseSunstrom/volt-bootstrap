// C++ calls shapelib (voltc bindings --lang cpp): a generic's instances as overloads, a struct held
// by a class with methods, owned values passed in, a Volt trait as an abstract class both ways,
// closures taking and giving text and handles, and closures given back as std::function
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
}
