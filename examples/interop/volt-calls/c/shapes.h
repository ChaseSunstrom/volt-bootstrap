// shapes.h: a small C library (shapes.c) that main.volt imports
#pragma once

typedef struct {
    double w, h;
} rect;

double rect_area(rect r);
void rect_scale(rect *r, double k);
const char *shape_name(int sides);
