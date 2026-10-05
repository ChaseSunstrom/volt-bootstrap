// raytrace: spheres on a ground sphere, one light with shadows and a highlight, mirror bounces, one
// ray per pixel; prints a checksum of the 8-bit pixels. C++ overloads + - * on a vec3 struct
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

struct vec3 {
    double x, y, z;
    vec3 operator+(const vec3 &o) const { return {x + o.x, y + o.y, z + o.z}; }
    vec3 operator-(const vec3 &o) const { return {x - o.x, y - o.y, z - o.z}; }
    vec3 operator*(double k) const { return {x * k, y * k, z * k}; }
    double dot(const vec3 &o) const { return x * o.x + y * o.y + z * o.z; }
    vec3 cross(const vec3 &o) const { return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x}; }
    vec3 normalize() const { return *this * (1.0 / std::sqrt(dot(*this))); }
};

struct sphere { vec3 center, color; double radius, reflect; };

static uint64_t rng = 88172645463325252ULL;
static uint64_t next() {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static double rand01() { return (double)(next() >> 11) / 9007199254740992.0; }

constexpr int max_depth = 4;
constexpr double eps = 1e-4;
constexpr double far = 1e30;
constexpr vec3 light = {-6.0, 10.0, 4.0};

// distance along the ray to the sphere, or far
static double hit(const sphere &s, const vec3 &o, const vec3 &d) {
    vec3 oc = o - s.center;
    double b = oc.dot(d);
    double c = oc.dot(oc) - s.radius * s.radius;
    double disc = b * b - c;
    if (disc < 0.0) return far;
    double sq = std::sqrt(disc);
    double t = -b - sq;
    if (t > eps) return t;
    t = -b + sq;
    if (t > eps) return t;
    return far;
}

static vec3 trace(const std::vector<sphere> &spheres, const vec3 &o, const vec3 &d, int depth) {
    double best = far;
    const sphere *s = nullptr;
    for (const sphere &sp : spheres) {
        double t = hit(sp, o, d);
        if (t < best) { best = t; s = &sp; }
    }
    if (!s) {
        double t = 0.5 * (d.y + 1.0);
        return vec3{1.0, 1.0, 1.0} * (1.0 - t) + vec3{0.5, 0.7, 1.0} * t;
    }
    vec3 p = o + d * best;
    vec3 n = (p - s->center).normalize();
    vec3 to_light = light - p;
    double dist = std::sqrt(to_light.dot(to_light));
    vec3 l = to_light * (1.0 / dist);
    double diffuse = n.dot(l);
    if (diffuse < 0.0) diffuse = 0.0;
    vec3 start = p + n * eps;
    if (diffuse > 0.0) {
        for (const sphere &sp : spheres) {
            if (hit(sp, start, l) < dist) { diffuse = 0.0; break; }
        }
    }
    double spec = 0.0;
    if (diffuse > 0.0) {
        spec = n.dot((l - d).normalize());
        for (int k = 0; k < 5; k++) spec *= spec;
    }
    vec3 color = s->color * (0.1 + 0.9 * diffuse) + vec3{1.0, 1.0, 1.0} * (0.5 * spec);
    if (depth < max_depth && s->reflect > 0.0) {
        vec3 r = d - n * (2.0 * d.dot(n));
        color = color * (1.0 - s->reflect) + trace(spheres, start, r, depth + 1) * s->reflect;
    }
    return color;
}

static int quantize(double c) {
    if (c < 0.0) c = 0.0;
    if (c > 1.0) c = 1.0;
    return (int)(c * 255.0);
}

int main(int argc, char **argv) {
    int width = argc > 1 ? std::atoi(argv[1]) : 2048;
    int height = width * 3 / 4;
    std::vector<sphere> spheres;
    spheres.push_back({{0.0, -1000.0, 0.0}, {0.5, 0.5, 0.5}, 1000.0, 0.25});
    for (int i = 0; i < 64; i++) {
        double r = 0.2 + 0.4 * rand01();
        double x = -6.0 + 12.0 * rand01();
        double z = -1.0 - 12.0 * rand01();
        double cr = rand01(), cg = rand01(), cb = rand01();
        double reflect = rand01() < 0.3 ? 0.6 : 0.0;
        spheres.push_back({{x, r, z}, {cr, cg, cb}, r, reflect});
    }
    vec3 eye{0.0, 2.0, 5.0};
    vec3 forward = (vec3{0.0, 0.5, -5.0} - eye).normalize();
    vec3 right = forward.cross({0.0, 1.0, 0.0}).normalize();
    vec3 up = right.cross(forward);
    double aspect = (double)width / (double)height;
    uint64_t check = 0;
    for (int py = 0; py < height; py++) {
        for (int px = 0; px < width; px++) {
            double u = (2.0 * (px + 0.5) / width - 1.0) * aspect * 0.6;
            double v = (1.0 - 2.0 * (py + 0.5) / height) * 0.6;
            vec3 d = (forward + right * u + up * v).normalize();
            vec3 c = trace(spheres, eye, d, 0);
            check = check * 31 + (uint64_t)quantize(c.x);
            check = check * 31 + (uint64_t)quantize(c.y);
            check = check * 31 + (uint64_t)quantize(c.z);
        }
    }
    std::printf("%dx%d %llu\n", width, height, (unsigned long long)check);
}
