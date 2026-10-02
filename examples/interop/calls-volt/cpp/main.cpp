// C++ calls the Volt library greet through its C++ header (bindings/greet.hpp): owned text comes
// back as std::string, an export struct is a class that frees itself
#include <cstdio>
#include "greet.hpp"

int main() {
    std::printf("add %lld\n", (long long)greet::add(2, 3));
    std::printf("%s\n", greet::hello("volt").c_str());
    greet::tally c("clicks");
    c.add(1);
    long long n = c.add(2);
    std::printf("%s %lld\n", c.name().c_str(), n);
}
