/* C calls the Volt library through voltc bindings --lang c */
#include <stdio.h>
#include <string.h>
#include "mathlib.h"

static void add_up(void *user, int32_t x) {
    *(int *)user += x;
    printf(" %d", x);
}

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
    // owned text: free it when done
    volt_text t = ml_greet((volt_str){(const uint8_t *)"volt", 4});
    printf("greet %.*s\n", (int)t.len, (const char *)t.ptr);
    volt_text_free(t);
    mathlib_math_error_or_text rt = ml_repeat((volt_str){(const uint8_t *)"ab", 2}, 2);
    printf("repeat %.*s\n", (int)rt.value.len, (const char *)rt.value.ptr);
    volt_text_free(rt.value);
    rt = ml_repeat((volt_str){(const uint8_t *)"ab", 2}, -1);
    printf("repeat %s\n", rt.error == MATHLIB_MATH_ERROR_NEGATIVE ? "negative" : "?");
    // slices and optionals
    double xs[] = {1, 2, 3.5};
    printf("sum %g\n", ml_sum((mathlib_slice_f64){xs, 3}));
    int32_t ys[] = {4, 5, 6};
    mathlib_opt_usize f = ml_find((mathlib_slice_i32){ys, 3}, 6), g = ml_find((mathlib_slice_i32){ys, 3}, 9);
    printf("find %zu %s\n", f.value, g.has ? "?" : "none");
    // a callback with our own data
    int total = 0;
    printf("each");
    ml_each((mathlib_slice_i32){ys, 3}, add_up, &total);
    printf(" = %d\n", total);
    // an export struct: a handle, freed with counter_free
    mathlib_counter *c = counter_new((volt_str){(const uint8_t *)"clicks", 6});
    counter_add(c, 2);
    volt_str n = counter_name(c);
    printf("counter %.*s %lld\n", (int)n.len, (const char *)n.ptr, (long long)counter_add(c, 3));
    mathlib_math_error_or_i64 k = counter_take(c, 9);
    printf("take %s\n", k.error == MATHLIB_MATH_ERROR_NEGATIVE ? "negative" : "?");
    counter_free(c);
    return 0;
}
