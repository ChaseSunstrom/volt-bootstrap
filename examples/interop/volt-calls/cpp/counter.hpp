// counter.hpp: a small C++ class (and a template) that main.volt imports
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

// a class with a virtual method: main.volt's type overrides it, and run() calls it from C++
class Ticker {
public:
    virtual ~Ticker() = default;
    virtual std::string tick(int n) const { return "tick " + std::to_string(n); }
    std::string run(int times) const {
        std::string out;
        for (int i = 1; i <= times; i++) {
            out += tick(i) + (i < times ? ", " : "");
        }
        return out;
    }
};

template <typename T>
T twice(T x) { return x + x; }

}  // namespace tally
