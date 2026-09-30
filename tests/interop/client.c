/* C calls the Volt library through voltc bindings --lang c */
#include <stdio.h>
#include <string.h>
#include "mathlib.h"

int main(void) {
    printf("add %d\n", ml_add(2, 3));
    mathlib_vec2 a = {1, 2}, b = {3, 4};
    printf("dot %g\n", ml_dot(a, b));
    ml_scale(&a, 2);
    printf("scale %g %g\n", a.x, a.y);
    volt_str s = {(const uint8_t *)"hello", 5};
    printf("len %zu\n", ml_len(s));
    printf("next %d\n", (int)ml_next(MATHLIB_COLOR_GREEN));
    mathlib_math_error_or_f64 r = ml_sqrt(9);
    printf("sqrt %g %d\n", r.value, r.error == 0);
    r = ml_sqrt(-1);
    printf("error %s\n", r.error == MATHLIB_MATH_ERROR_NEGATIVE ? "negative" : "?");
    return 0;
}
