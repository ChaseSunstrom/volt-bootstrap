/* wrapped functions (long double, _Complex) whose C types a wrapper can't spell exactly, for
   tests/run/c_wrappers.volt */

/* long is long long by width, a const char * a char * */
static inline long double ld_add(long *n, const char *digit) { return *n + (digit[0] - '0'); }
static inline long *ld_store(long *n, long double x) { *n = (long)x; return n; }
static inline long double ld_first(const char **words) { return words[0][0] - '0'; }

/* the header's own cf64, next to a complex function (Volt's complex struct is another name) */
typedef struct { int a, b; } cf64;
static inline double _Complex c_swap(double _Complex z) { return __builtin_complex(__imag__ z, __real__ z); }
static inline int cf64_sum(cf64 c) { return c.a + c.b; }

/* bound to another symbol, as glibc's __REDIRECT does */
#define C_WRAPPERS_STR2(x) #x
#define C_WRAPPERS_STR(x) C_WRAPPERS_STR2(x)
long double ld_parse(const char *s, char **end) __asm__(C_WRAPPERS_STR(__USER_LABEL_PREFIX__) "strtold");
