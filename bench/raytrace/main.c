// raytrace: spheres on a ground sphere, one light with shadows and a highlight, mirror bounces, one
// ray per pixel; prints a checksum of the 8-bit pixels. C passes a vec3 struct to add/sub/scale/dot
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { double x, y, z; } vec3;
typedef struct { vec3 center, color; double radius, reflect; } sphere;

static vec3 v3(double x, double y, double z) { vec3 v = {x, y, z}; return v; }
static vec3 add(vec3 a, vec3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
static vec3 sub(vec3 a, vec3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
static vec3 scale(vec3 a, double k) { return v3(a.x * k, a.y * k, a.z * k); }
static double dot(vec3 a, vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static vec3 cross(vec3 a, vec3 b) { return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static vec3 normalize(vec3 a) { return scale(a, 1.0 / sqrt(dot(a, a))); }

static uint64_t rng = 88172645463325252ULL;
static uint64_t next(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static double rand01(void) { return (double)(next() >> 11) / 9007199254740992.0; }

#define MAX_DEPTH 4
#define EPS 1e-4
#define FAR 1e30

static const vec3 light = {-6.0, 10.0, 4.0};

// distance along the ray to the sphere, or FAR
static double hit(const sphere *s, vec3 o, vec3 d) {
    vec3 oc = sub(o, s->center);
    double b = dot(oc, d);
    double c = dot(oc, oc) - s->radius * s->radius;
    double disc = b * b - c;
    if (disc < 0.0) return FAR;
    double sq = sqrt(disc);
    double t = -b - sq;
    if (t > EPS) return t;
    t = -b + sq;
    if (t > EPS) return t;
    return FAR;
}

static vec3 trace(const sphere *spheres, int n, vec3 o, vec3 d, int depth) {
    double best = FAR;
    const sphere *s = NULL;
    for (int i = 0; i < n; i++) {
        double t = hit(&spheres[i], o, d);
        if (t < best) { best = t; s = &spheres[i]; }
    }
    if (!s) {
        double t = 0.5 * (d.y + 1.0);
        return add(scale(v3(1.0, 1.0, 1.0), 1.0 - t), scale(v3(0.5, 0.7, 1.0), t));
    }
    vec3 p = add(o, scale(d, best));
    vec3 nrm = normalize(sub(p, s->center));
    vec3 to_light = sub(light, p);
    double dist = sqrt(dot(to_light, to_light));
    vec3 l = scale(to_light, 1.0 / dist);
    double diffuse = dot(nrm, l);
    if (diffuse < 0.0) diffuse = 0.0;
    vec3 start = add(p, scale(nrm, EPS));
    if (diffuse > 0.0) {
        for (int i = 0; i < n; i++) {
            if (hit(&spheres[i], start, l) < dist) { diffuse = 0.0; break; }
        }
    }
    double spec = 0.0;
    if (diffuse > 0.0) {
        spec = dot(nrm, normalize(sub(l, d)));
        for (int k = 0; k < 5; k++) spec *= spec;
    }
    vec3 color = add(scale(s->color, 0.1 + 0.9 * diffuse), scale(v3(1.0, 1.0, 1.0), 0.5 * spec));
    if (depth < MAX_DEPTH && s->reflect > 0.0) {
        vec3 r = sub(d, scale(nrm, 2.0 * dot(d, nrm)));
        color = add(scale(color, 1.0 - s->reflect), scale(trace(spheres, n, start, r, depth + 1), s->reflect));
    }
    return color;
}

static int quantize(double c) {
    if (c < 0.0) c = 0.0;
    if (c > 1.0) c = 1.0;
    return (int)(c * 255.0);
}

int main(int argc, char **argv) {
    int width = argc > 1 ? atoi(argv[1]) : 2048;
    int height = width * 3 / 4;
    int n = 64;
    sphere *spheres = malloc((n + 1) * sizeof *spheres);
    spheres[0] = (sphere){v3(0.0, -1000.0, 0.0), v3(0.5, 0.5, 0.5), 1000.0, 0.25};
    for (int i = 1; i <= n; i++) {
        double r = 0.2 + 0.4 * rand01();
        double x = -6.0 + 12.0 * rand01();
        double z = -1.0 - 12.0 * rand01();
        double cr = rand01(), cg = rand01(), cb = rand01();
        double reflect = rand01() < 0.3 ? 0.6 : 0.0;
        spheres[i] = (sphere){v3(x, r, z), v3(cr, cg, cb), r, reflect};
    }
    n++;
    vec3 eye = v3(0.0, 2.0, 5.0);
    vec3 forward = normalize(sub(v3(0.0, 0.5, -5.0), eye));
    vec3 right = normalize(cross(forward, v3(0.0, 1.0, 0.0)));
    vec3 up = cross(right, forward);
    double aspect = (double)width / (double)height;
    uint64_t check = 0;
    for (int py = 0; py < height; py++) {
        for (int px = 0; px < width; px++) {
            double u = (2.0 * (px + 0.5) / width - 1.0) * aspect * 0.6;
            double v = (1.0 - 2.0 * (py + 0.5) / height) * 0.6;
            vec3 d = normalize(add(add(forward, scale(right, u)), scale(up, v)));
            vec3 c = trace(spheres, n, eye, d, 0);
            check = check * 31 + (uint64_t)quantize(c.x);
            check = check * 31 + (uint64_t)quantize(c.y);
            check = check * 31 + (uint64_t)quantize(c.z);
        }
    }
    printf("%dx%d %llu\n", width, height, (unsigned long long)check);
    free(spheres);
    return 0;
}
