// shapes.c: the C library main.volt calls (its header is shapes.h)
#include "shapes.h"

double rect_area(rect r) { return r.w * r.h; }

void rect_scale(rect *r, double k) {
    r->w *= k;
    r->h *= k;
}

const char *shape_name(int sides) {
    return sides == 3 ? "triangle" : sides == 4 ? "square" : "shape";
}
