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

#define TEXT(t) (int)(t).len, (const char *)(t).ptr

// lists (std::vec), slices of text and handles, optional text and handles
// C's own tagged: its fns are named like words C keeps (int is int_)
static int32_t tg_type(void *self) {
    (void)self;
    return 1;
}

static int32_t tg_from(void *self, int32_t x) {
    (void)self;
    return x + 1;
}

static int32_t tg_int(void *self) {
    (void)self;
    return 2;
}

static int32_t tg_close(void *self) {
    (void)self;
    return 3;
}

static const shapelib_tagged_vt tg_vt = {tg_type, tg_from, tg_int, tg_close};

static void lists(void) {
    shapelib_account *a = account_open(S("ann"));
    account_deposit(a, 5);
    shapelib_account *b = account_open(S("bobby"));
    account_deposit(b, 9);
    shapelib_account *ab[] = {a, b};
    shapelib_slice_shapelib_account both = {ab, 2};
    shapelib_list_text os = owners(both);
    printf("owners %zu %.*s %.*s\n", os.len, TEXT(os.ptr[0]), TEXT(os.ptr[1]));
    volt_list_free(os);
    printf("richest %lld", (long long)richest(both));
    printf(" after %lld %lld\n", (long long)account_get(a), (long long)account_get(b));
    volt_str names[] = {S("cy"), S("dee")};
    shapelib_slice_str ns = {names, 2};
    shapelib_list_account opened = open_all(ns);
    printf("opened %zu %.*s\n", opened.len, TEXT(account_owner(opened.ptr[1])));
    // the handles are the caller's; the list holds their pointers
    for (size_t i = 0; i < opened.len; i++) {
        account_free(opened.ptr[i]);
    }
    volt_list_free(opened);
    shapelib_list_i64 sq = squares_upto(4);
    shapelib_slice_i64 sqs = {sq.ptr, sq.len};
    printf("squares %zu %lld sum %lld\n", sq.len, (long long)sq.ptr[3], (long long)sum_all(sqs));
    volt_list_free(sq);
    volt_str parts[] = {S("a"), S("b"), S("c")};
    shapelib_slice_str ps = {parts, 3};
    volt_text j = joined(ps, S("-"));
    printf("joined %.*s total %lld\n", TEXT(j), (long long)total_len(ps));
    volt_text_free(j);
    shapelib_opt_str ann = {S("ann"), true};
    shapelib_opt_str none = {{0}, false};
    volt_text g1 = greeting(ann);
    volt_text g2 = greeting(none);
    printf("%.*s; %.*s\n", TEXT(g1), TEXT(g2));
    volt_text_free(g1);
    volt_text_free(g2);
    shapelib_opt_text n1 = nickname(a);
    shapelib_opt_text n2 = nickname(b);
    printf("nick %d %.*s %d\n", n1.has, TEXT(n1.value), n2.has);
    if (n1.has) {
        volt_text_free(n1.value);
    }
    shapelib_account *c = open_if(S("eve"), true);
    shapelib_account *d = open_if(S("x"), false);
    printf("open_if %d %d\n", c != NULL, d == NULL);
    printf("close_if %lld %lld\n", (long long)close_if(c), (long long)close_if(NULL));
    printf("close_all %lld\n", (long long)close_all(both));
    shapelib_opt_i64 some[] = {{1, true}, {0, false}, {3, true}};
    shapelib_slice_opt_i64 ss = {some, 3};
    printf("some %lld\n", (long long)count_some(ss));
    int64_t r1[] = {1, 2}, r2[] = {3};
    shapelib_slice_i64 rr[] = {{r1, 2}, {r2, 1}};
    printf("rows %lld\n", (long long)total_rows((shapelib_slice_slice_i64){rr, 2}));
    shapelib_array_i64_3 rot = rotated((shapelib_array_i64_3){{11, 12, 13}});
    shapelib_array_f64_2 sw = swapped((shapelib_array_f64_2){{1.5, 2.5}});
    shapelib_array_u8_3 bu = bumped((shapelib_array_u8_3){{1, 2, 3}});
    printf("arrays %lld %lld %lld %g %g %d %d %d\n", (long long)rot.v[0], (long long)rot.v[1], (long long)rot.v[2], sw.v[0], sw.v[1], bu.v[0], bu.v[1], bu.v[2]);
    shapelib_tagged tl = {&tg_vt, NULL, NULL};
    shapelib_tagged tv = make_tagged(5);
    printf("tagged %d %d %d %d %d %d\n", tagged_sum(tl), tv.vt->type(tv.self), tv.vt->from(tv.self, 4), tv.vt->int_(tv.self), tv.vt->close(tv.self), tagged_sum(tv));
    tv.drop(tv.self);
    printf("lists closed %d\n", closed_accounts());
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
    lists();
    printf("circle gone\n");
    return 0;
}
