// shapes: a million shapes of four kinds, their total area and perimeter summed over many rounds
// through dynamic dispatch; C++ derives four classes from an abstract base with virtual functions
// and keeps them in a std::vector<std::unique_ptr<shape>>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

constexpr double pi = 3.141592653589793;

struct shape {
    virtual ~shape() = default;
    virtual double area() const = 0;
    virtual double perimeter() const = 0;
};

static double dist(double ax, double ay, double bx, double by) {
    double dx = bx - ax, dy = by - ay;
    return std::sqrt(dx * dx + dy * dy);
}

struct circle : shape {
    double r;
    explicit circle(double r) : r(r) {}
    double area() const override { return pi * r * r; }
    double perimeter() const override { return 2.0 * pi * r; }
};

struct rect : shape {
    double w, h;
    rect(double w, double h) : w(w), h(h) {}
    double area() const override { return w * h; }
    double perimeter() const override { return 2.0 * (w + h); }
};

struct triangle : shape {
    double x0, y0, x1, y1, x2, y2;
    triangle(double x0, double y0, double x1, double y1, double x2, double y2) : x0(x0), y0(y0), x1(x1), y1(y1), x2(x2), y2(y2) {}
    double area() const override { return 0.5 * ((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)); }
    double perimeter() const override { return dist(x0, y0, x1, y1) + dist(x1, y1, x2, y2) + dist(x2, y2, x0, y0); }
};

struct quad : shape {
    std::array<double, 4> x, y;
    quad(std::array<double, 4> x, std::array<double, 4> y) : x(x), y(y) {}
    double area() const override {
        double sum = 0.0;
        for (int i = 0; i < 4; i++) {
            int j = (i + 1) % 4;
            sum += x[i] * y[j] - x[j] * y[i];
        }
        return 0.5 * sum;
    }
    double perimeter() const override {
        double sum = 0.0;
        for (int i = 0; i < 4; i++) {
            int j = (i + 1) % 4;
            sum += dist(x[i], y[i], x[j], y[j]);
        }
        return sum;
    }
};

static uint64_t rng = 88172645463325252ULL;
static uint64_t next() {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static double rand01() { return (double)(next() >> 11) / 9007199254740992.0; }

static std::unique_ptr<shape> make_shape() {
    switch (next() % 4) {
    case 0:
        return std::make_unique<circle>(0.5 + 2.0 * rand01());
    case 1: {
        double w = 0.5 + 3.0 * rand01();
        double h = 0.5 + 3.0 * rand01();
        return std::make_unique<rect>(w, h);
    }
    case 2: {
        double x = 10.0 * rand01();
        double y = 10.0 * rand01();
        double a = 0.5 + 2.0 * rand01();
        double b = 2.0 * rand01();
        double c = 0.5 + 2.0 * rand01();
        return std::make_unique<triangle>(x, y, x + a, y, x + b, y + c);
    }
    default: {
        double cx = 10.0 * rand01();
        double cy = 10.0 * rand01();
        double a = 0.5 + 1.5 * rand01();
        double b = 0.5 + 1.5 * rand01();
        double c = 0.5 + 1.5 * rand01();
        double d = 0.5 + 1.5 * rand01();
        return std::make_unique<quad>(std::array{cx + a, cx, cx - c, cx}, std::array{cy, cy + b, cy, cy - d});
    }
    }
}

int main(int argc, char **argv) {
    long rounds = argc > 1 ? std::atol(argv[1]) : 100;
    size_t n = 1000000;
    std::vector<std::unique_ptr<shape>> shapes;
    shapes.reserve(n);
    for (size_t i = 0; i < n; i++) shapes.push_back(make_shape());
    double area = 0.0, perimeter = 0.0;
    for (long r = 0; r < rounds; r++) {
        for (const auto &s : shapes) {
            area += s->area();
            perimeter += s->perimeter();
        }
    }
    std::printf("%lld %lld\n", (long long)area, (long long)perimeter);
}
