// counter.hpp: a small C++ class that examples/interop/counter.volt imports (use { "counter.hpp" })
#pragma once
#include <cstdio>
#include <string>

namespace tally {

class Counter {
public:
    explicit Counter(int start = 0) : n(start) {}
    ~Counter() { std::printf("counter done at %d\n", n); }
    void add(int k = 1) { n += k; }
    int value() const { return n; }
    static const char *unit() { return "clicks"; }

private:
    int n;
    std::string label = "a string Volt never sees";
};

template <typename T>
T twice(T x) { return x + x; }

}  // namespace tally
