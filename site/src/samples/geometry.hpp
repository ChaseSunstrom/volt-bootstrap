// A small C++ library for the interop sample (site/src/samples/interop.volt)
#pragma once
#include <cmath>

namespace geo {

struct Vec2 {
    double x, y;
    double length() const { return std::sqrt(x * x + y * y); }
};

class Path {
public:
    Path() : count(0) {}
    void add(Vec2 p) { points[count++] = p; }
    double length() const {
        double total = 0;
        for (int i = 1; i < count; i++) {
            Vec2 d{points[i].x - points[i - 1].x, points[i].y - points[i - 1].y};
            total += d.length();
        }
        return total;
    }

private:
    Vec2 points[16];
    int count;
};

template <typename T>
T clamp(T v, T lo, T hi) { return v < lo ? lo : v > hi ? hi : v; }

}
