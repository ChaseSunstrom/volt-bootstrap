// C calls shapelib (voltc bindings --lang c): a generic's instances by their C names, a struct held
// by a handle with its methods, owned values passed in, a Volt trait as a table of functions both
// ways, callbacks taking and giving text and handles, and closures given back
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shapelib.h"

static volt_str S(const char *s) {
    volt_str v = {(const uint8_t *)s, strlen(s)};
    return v;
}

static void free_bytes(void *p) {
    free(p);
}

// text C gives Volt: Volt calls drop when it's done
static volt_text give(const char *s, size_t n) {
    char *b = malloc(n);
    memcpy(b, s, n);
    volt_text t = {(const uint8_t *)b, n, b, free_bytes};
    return t;
}

// C's own shape
typedef struct {
    double r;
} circle;

static double circle_area(void *self) {
    circle *c = self;
    return 3 * c->r * c->r;
}

static volt_text circle_name(void *self) {
    (void)self;
    return give("circle", 6);
}

static void circle_grow(void *self, double by) {
    ((circle *)self)->r += by;
}

static void circle_free(void *self) {
    printf("circle gone\n");
    free(self);
}

static const shapelib_shape_vt circle_vt = {circle_area, circle_name, circle_grow};

static volt_text shout_cb(void *user, volt_str s) {
    (void)user;
    char buf[64];
    memcpy(buf, s.ptr, s.len);
    buf[s.len] = '!';
    return give(buf, s.len + 1);
}

static int64_t visit_cb(void *user, shapelib_account *a) {
    (void)user;
    return account_deposit(a, 1);
}

static shapelib_bank_error_or_i32 twice_cb(void *user, int32_t x) {
    (void)user;
    shapelib_bank_error_or_i32 r = {0, x * 2};
    if (x > 5) {
        r.error = SHAPELIB_BANK_ERROR_OVERDRAWN;
    }
    return r;
}

static shapelib_account *open_cb(void *user, volt_str owner) {
    (void)user;
    shapelib_account *a = account_open(owner);
    account_deposit(a, 7);
    return a;
}

int main(void) {
    int32_t xs[] = {3, 9, 4};
    double ys[] = {1.5, 0.5};
    shapelib_slice_i32 xsl = {xs, 3};
    shapelib_slice_f64 ysl = {ys, 2};
    printf("biggest %d %g\n", biggest_i32(xsl), biggest_f64(ysl));
    shapelib_account *a = account_open(S("ann"));
    account_deposit(a, 250);
    account_rename(a, S("bea"));
    long long n = account_deposit(a, 50);
    volt_str o = account_owner(a);
    printf("account %.*s %lld\n", (int)o.len, (const char *)o.ptr, n);
    n = visit(a, visit_cb, NULL);
    printf("visit %lld get %lld\n", n, (long long)account_get(a));
    n = close_account(a);
    printf("closed %lld %d\n", n, closed_accounts());
    circle c = {1};
    shapelib_shape lent = {&circle_vt, &c, NULL};
    volt_text t = describe(lent);
    printf("%.*s\n", (int)t.len, (const char *)t.ptr);
    volt_text_free(t);
    circle *owned = malloc(sizeof *owned);
    owned->r = 1;
    shapelib_shape given = {&circle_vt, owned, circle_free};
    double g = grow_twice(given);
    printf("grown %g\n", g);
    shapelib_shape sq = make_square(2);
    sq.vt->grow(sq.self, 1);
    volt_text nm = sq.vt->name(sq.self);
    volt_text ds = describe(sq);
    printf("%.*s %g %.*s\n", (int)nm.len, (const char *)nm.ptr, sq.vt->area(sq.self), (int)ds.len, (const char *)ds.ptr);
    volt_text_free(nm);
    volt_text_free(ds);
    sq.drop(sq.self);
    t = shout(shout_cb, NULL, S("hey"));
    printf("%.*s\n", (int)t.len, (const char *)t.ptr);
    volt_text_free(t);
    shapelib_bank_error_or_i32 tr = try_twice(twice_cb, NULL, 1);
    printf("try %d", tr.value);
    tr = try_twice(twice_cb, NULL, 4);
    printf(" %s\n", tr.error == SHAPELIB_BANK_ERROR_OVERDRAWN ? "OVERDRAWN" : "?");
    n = opened_by(open_cb, NULL);
    printf("opened %lld\n", n);
    printf("closed %d\n", closed_accounts());
    shapelib_closure1 d = doubler();
    shapelib_closure2 hi = greeter();
    t = hi.call(hi.self, S("volt"));
    printf("%d %.*s\n", d.call(d.self, 21), (int)t.len, (const char *)t.ptr);
    volt_text_free(t);
    d.drop(d.self);
    hi.drop(hi.self);
    printf("circle gone\n");
    return 0;
}
