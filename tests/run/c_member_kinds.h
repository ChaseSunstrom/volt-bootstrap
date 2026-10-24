/* members of kinds the C import once skipped (c_member_kinds.volt): _Atomic scalars, _Float16,
   unsigned __int128 and a flexible array member, beside a vector */
#include <stdatomic.h>
#include <stdlib.h>

typedef int v4i __attribute__((vector_size(16)));

struct kinds {
    v4i v;
    _Atomic int a;
    _Atomic(long long) al;
    _Float16 h;
    unsigned __int128 big;
    int n;
    int tail[];
};

static inline struct kinds *kinds_new(int n) {
    struct kinds *k = (struct kinds *)calloc(1, sizeof(struct kinds) + (size_t)n * sizeof(int));
    k->n = n;
    return k;
}

static inline long long kinds_sum(const struct kinds *k) {
    long long s = k->a + k->al + (long long)k->h + (long long)(k->big >> 64);
    for (int i = 0; i < k->n; i++) s += k->tail[i];
    return s;
}
