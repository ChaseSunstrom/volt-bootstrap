/* C calls the Volt library through voltc bindings --lang c */
#include <stdio.h>
#include <string.h>
#include "mathlib.h"

static void add_up(void *user, int32_t x) {
    *(int *)user += x;
    printf(" %d", x);
}

// a callback giving a struct with text (a literal: it outlives the call)
static mathlib_ml_label give_label(void *user, int32_t k) {
    (void)user;
    return (mathlib_ml_label){{(const uint8_t *)"abc", 3}, {k, k, k}, {3, 0}};
}

// callbacks giving a slice (in memory of the client's: Volt reads it before calling again)
static int64_t given[2];
static mathlib_vec2 points[2];

static mathlib_slice_i64 give_pair(void *user, int32_t k) {
    (void)user;
    given[0] = k;
    given[1] = 10 * (int64_t)k;
    return (mathlib_slice_i64){given, 2};
}

static mathlib_slice_vec2 give_points(void *user, int32_t k) {
    (void)user;
    points[0] = (mathlib_vec2){1.5, k};
    points[1] = (mathlib_vec2){2, 3.25};
    return (mathlib_slice_vec2){points, 2};
}

int main(void) {
    printf("add %d\n", ml_add(2, 3));
    mathlib_vec2 a = {1, 2}, b = {3, 4};
    printf("dot %g\n", ml_dot(a, b));
    ml_scale(&a, 2);
    printf("scale %g %g\n", a.x, a.y);
    volt_str s = {(const uint8_t *)"hello", 5};
    printf("len %zu\n", ml_len(s));
    volt_str ab = {(const uint8_t *)"ab", 2};
    printf("clash %d\n", ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, ab, 13, 14));
    mathlib_ml_tags tg = ml_tags_make();
    printf("tags %d %d %d %d", tg.from, tg.type, tg.self, tg.int_);
    tg.int_ = 5;
    printf(" %d\n", ml_tags_sum(tg));
    int32_t bp = 7;
    double bq = 2.5;
    ml_bump(&bp, &bq);
    printf("bump %d %g\n", bp, bq);
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
    // structs with text, an array and a struct in them (in, out, in a slice, from a callback), one
    // with a pointer, E!T as a parameter
    mathlib_ml_label la = {{(const uint8_t *)"ab", 2}, {1, 2, 3}, {7, 0}};
    printf("label %lld\n", (long long)ml_label_len(la));
    mathlib_ml_label lb = ml_label_of((volt_str){(const uint8_t *)"ab", 2}, 3);
    printf("label_of %.*s %d %d %d %g\n", (int)lb.name.len, (const char *)lb.name.ptr, lb.sizes[0], lb.sizes[1], lb.sizes[2], lb.at.x);
    mathlib_ml_label ls[] = {la, lb};
    printf("labels %lld\n", (long long)ml_labels_len((mathlib_slice_ml_label){ls, 2}));
    printf("holder %d\n", ml_holder_k((mathlib_ml_holder){NULL, 3}));
    printf("or %g %g\n", ml_or((mathlib_math_error_or_f64){0, 4.5}, 9.5), ml_or((mathlib_math_error_or_f64){MATHLIB_MATH_ERROR_NEGATIVE, 0}, 9.5));
    printf("ask %lld\n", (long long)ml_ask(give_label, NULL));
    ml_relabel(&lb, 4);
    printf("relabel %.*s %d %d %d\n", (int)lb.name.len, (const char *)lb.name.ptr, lb.sizes[0], lb.sizes[1], lb.sizes[2]);
    mathlib_ml_label both[] = {la, lb};
    printf("count %lld\n", (long long)ml_labels_count((mathlib_slice_ml_label){both, 2}));
    printf("note %lld\n", (long long)ml_note_len((mathlib_ml_note){.str = {(const uint8_t *)"abc", 3}, .c = 1, .k = 3}));
    printf("or_label %lld %lld\n", (long long)ml_or_label((mathlib_math_error_or_ml_label){.error = 0, .value = la}), (long long)ml_or_label((mathlib_math_error_or_ml_label){.error = MATHLIB_MATH_ERROR_NEGATIVE}));
    printf("given %lld %g\n", (long long)ml_sum_given(3, give_pair, NULL), ml_area_given(give_points, NULL));
    int64_t d00[] = {1, 2}, d01[] = {3}, d10[] = {4};
    mathlib_slice_i64 d0[] = {{d00, 2}, {d01, 1}}, d1[] = {{d10, 1}};
    mathlib_slice_slice_i64 dd[] = {{d0, 2}, {d1, 1}};
    long long deep = ml_deep((mathlib_slice_slice_slice_i64){dd, 2});
    volt_str w0[] = {{(const uint8_t *)"ab", 2}, {(const uint8_t *)"c", 1}}, w2[] = {{(const uint8_t *)"def", 3}};
    mathlib_slice_str ws[] = {{w0, 2}, {NULL, 0}, {w2, 1}};
    printf("deep %lld %lld %lld words %lld\n", deep, (long long)d00[1], (long long)d10[0], (long long)ml_words((mathlib_slice_slice_str){ws, 3}));
    return 0;
}
