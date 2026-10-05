// shapes: a million shapes of four kinds, their total area and perimeter summed over many rounds
// through dynamic dispatch; C gives each shape a pointer to a struct of function pointers and keeps
// an array of pointers to them, each malloc'd
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define PI 3.141592653589793

typedef struct shape shape;
typedef struct {
    double (*area)(const shape *);
    double (*perimeter)(const shape *);
} shape_vtable;
struct shape { const shape_vtable *vt; };

static double dist(double ax, double ay, double bx, double by) {
    double dx = bx - ax, dy = by - ay;
    return sqrt(dx * dx + dy * dy);
}

typedef struct { shape base; double r; } circle;
static double circle_area(const shape *s) { const circle *c = (const circle *)s; return PI * c->r * c->r; }
static double circle_perimeter(const shape *s) { const circle *c = (const circle *)s; return 2.0 * PI * c->r; }
static const shape_vtable circle_vt = {circle_area, circle_perimeter};

typedef struct { shape base; double w, h; } rect;
static double rect_area(const shape *s) { const rect *r = (const rect *)s; return r->w * r->h; }
static double rect_perimeter(const shape *s) { const rect *r = (const rect *)s; return 2.0 * (r->w + r->h); }
static const shape_vtable rect_vt = {rect_area, rect_perimeter};

typedef struct { shape base; double x0, y0, x1, y1, x2, y2; } triangle;
static double triangle_area(const shape *s) {
    const triangle *t = (const triangle *)s;
    return 0.5 * ((t->x1 - t->x0) * (t->y2 - t->y0) - (t->x2 - t->x0) * (t->y1 - t->y0));
}
static double triangle_perimeter(const shape *s) {
    const triangle *t = (const triangle *)s;
    return dist(t->x0, t->y0, t->x1, t->y1) + dist(t->x1, t->y1, t->x2, t->y2) + dist(t->x2, t->y2, t->x0, t->y0);
}
static const shape_vtable triangle_vt = {triangle_area, triangle_perimeter};

typedef struct { shape base; double x[4], y[4]; } quad;
static double quad_area(const shape *s) {
    const quad *q = (const quad *)s;
    double sum = 0.0;
    for (int i = 0; i < 4; i++) {
        int j = (i + 1) % 4;
        sum += q->x[i] * q->y[j] - q->x[j] * q->y[i];
    }
    return 0.5 * sum;
}
static double quad_perimeter(const shape *s) {
    const quad *q = (const quad *)s;
    double sum = 0.0;
    for (int i = 0; i < 4; i++) {
        int j = (i + 1) % 4;
        sum += dist(q->x[i], q->y[i], q->x[j], q->y[j]);
    }
    return sum;
}
static const shape_vtable quad_vt = {quad_area, quad_perimeter};

static uint64_t rng = 88172645463325252ULL;
static uint64_t next(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static double rand01(void) { return (double)(next() >> 11) / 9007199254740992.0; }

static shape *make_shape(void) {
    switch (next() % 4) {
    case 0: {
        circle *c = malloc(sizeof *c);
        c->base.vt = &circle_vt;
        c->r = 0.5 + 2.0 * rand01();
        return &c->base;
    }
    case 1: {
        rect *r = malloc(sizeof *r);
        r->base.vt = &rect_vt;
        r->w = 0.5 + 3.0 * rand01();
        r->h = 0.5 + 3.0 * rand01();
        return &r->base;
    }
    case 2: {
        triangle *t = malloc(sizeof *t);
        t->base.vt = &triangle_vt;
        double x = 10.0 * rand01();
        double y = 10.0 * rand01();
        double a = 0.5 + 2.0 * rand01();
        double b = 2.0 * rand01();
        double c = 0.5 + 2.0 * rand01();
        t->x0 = x; t->y0 = y;
        t->x1 = x + a; t->y1 = y;
        t->x2 = x + b; t->y2 = y + c;
        return &t->base;
    }
    default: {
        quad *q = malloc(sizeof *q);
        q->base.vt = &quad_vt;
        double cx = 10.0 * rand01();
        double cy = 10.0 * rand01();
        double a = 0.5 + 1.5 * rand01();
        double b = 0.5 + 1.5 * rand01();
        double c = 0.5 + 1.5 * rand01();
        double d = 0.5 + 1.5 * rand01();
        q->x[0] = cx + a; q->y[0] = cy;
        q->x[1] = cx; q->y[1] = cy + b;
        q->x[2] = cx - c; q->y[2] = cy;
        q->x[3] = cx; q->y[3] = cy - d;
        return &q->base;
    }
    }
}

int main(int argc, char **argv) {
    long rounds = argc > 1 ? atol(argv[1]) : 100;
    size_t n = 1000000;
    shape **shapes = malloc(n * sizeof *shapes);
    for (size_t i = 0; i < n; i++) shapes[i] = make_shape();
    double area = 0.0, perimeter = 0.0;
    for (long r = 0; r < rounds; r++) {
        for (size_t i = 0; i < n; i++) {
            const shape *s = shapes[i];
            area += s->vt->area(s);
            perimeter += s->vt->perimeter(s);
        }
    }
    printf("%lld %lld\n", (long long)area, (long long)perimeter);
    for (size_t i = 0; i < n; i++) free(shapes[i]);
    free(shapes);
    return 0;
}
