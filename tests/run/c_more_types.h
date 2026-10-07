/* long double, _Complex and named enums, which have no Volt type of their own */
enum axis { AXIS_X, AXIS_Y, AXIS_Z = 4 };
typedef enum { MODE_OFF = -1, MODE_ON = 1, MODE_DEFAULT = 1 } mode;
enum { ANON_LIMIT = 9 };

static inline long double ld_half(long double x) { return x / 2; }
static inline long double ld_scale(long double x, int k, long double *out) { if (out) *out = x * k; return x * k + 1; }
static inline double _Complex c_mul(double _Complex a, double _Complex b) { return a * b; }
static inline float _Complex cf_twice(float _Complex z) { return z * 2; }
static inline long double _Complex cl_swap(long double _Complex z) { return __builtin_complex(__imag__ z, __real__ z); }
static inline double c_norm(double _Complex z) { return __real__ z * __real__ z + __imag__ z * __imag__ z; }

static inline int axis_rank(enum axis a) { return a == AXIS_Z ? 3 : (int)a + 1; }
static inline enum axis axis_next(enum axis a) { return a == AXIS_X ? AXIS_Y : AXIS_Z; }
static inline int mode_flip(mode m) { return -(int)m; }
static inline void axis_last(enum axis *out) { *out = AXIS_Z; }

struct sample { enum axis along; double _Complex at; };
static inline double sample_sum(const struct sample *s) { return (int)s->along + __real__ s->at + __imag__ s->at; }
static inline void sample_set(struct sample *s, double _Complex z) { s->at = z; }
