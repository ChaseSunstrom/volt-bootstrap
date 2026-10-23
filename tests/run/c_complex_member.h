/* complex members and pointers to complexes (c_complex_member.volt): C11 lays a complex out as two
   of its reals, as the import's cf32/cf64 are */
#include <complex.h>

struct wave {
    double _Complex z;
    int n;
    float _Complex f;
};

static inline void scale(double _Complex *p, double k) { *p = *p * k; }
static inline void flip(struct wave *w) { w->z = conj(w->z); w->f = w->f * 2.0f; w->n += 1; }
static inline double mag2(struct wave w) { return creal(w.z) * creal(w.z) + cimag(w.z) * cimag(w.z); }
