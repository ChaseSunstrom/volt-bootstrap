/* Volt runtime prelude: no libc headers, so user extern "C" declarations and #included headers
   never conflict. libc functions are declared under volt_ names bound to the real symbols. */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdarg.h>
#define VOLT_S2(x) #x
#define VOLT_S(x) VOLT_S2(x)
#define VOLT_SYM(n) __asm__(VOLT_S(__USER_LABEL_PREFIX__) n)
/* the helpers below: private to each C unit; the LLVM backend's runtime object makes them weak */
#ifndef VOLT_RT_LINKAGE
#define VOLT_RT_LINKAGE static __attribute__((unused))
#endif
/* async frame states past the suspend points: finished (result inside), result taken */
#define VOLT_DONE 0xFFFFFFFEu
#define VOLT_TAKEN 0xFFFFFFFFu
int volt_printf(const char *, ...) VOLT_SYM("printf");
int volt_vprintf(const char *, va_list) VOLT_SYM("vprintf");
int volt_vdprintf(int, const char *, va_list) VOLT_SYM("vdprintf");
int volt_dprintf(int, const char *, ...) VOLT_SYM("dprintf");
int volt_snprintf(char *, size_t, const char *, ...) VOLT_SYM("snprintf");
int volt_vsnprintf(char *, size_t, const char *, va_list) VOLT_SYM("vsnprintf");
double volt_strtod(const char *, char **) VOLT_SYM("strtod");
_Noreturn void volt_exit(int) VOLT_SYM("exit");
void *volt_malloc(size_t) VOLT_SYM("malloc");
void *volt_realloc(void *, size_t) VOLT_SYM("realloc");
void volt_free(void *) VOLT_SYM("free");
int volt_memcmp(const void *, const void *, size_t) VOLT_SYM("memcmp");
void *volt_memcpy(void *, const void *, size_t) VOLT_SYM("memcpy");
void *volt_memset(void *, int, size_t) VOLT_SYM("memset");
size_t volt_strlen(const char *) VOLT_SYM("strlen");

typedef struct { const uint8_t *ptr; size_t len; } volt_str;

VOLT_RT_LINKAGE _Noreturn void volt_panic(const char *msg, const char *loc) {
    volt_dprintf(2, "%s: panic: %s\n", loc, msg);
    volt_exit(101);
}
VOLT_RT_LINKAGE _Noreturn void volt_panic_str(volt_str msg, const char *loc) {
    volt_dprintf(2, "%s: panic: %.*s\n", loc, (int)msg.len, (const char *)msg.ptr);
    volt_exit(101);
}
VOLT_RT_LINKAGE _Noreturn void volt_bounds(size_t i, size_t len, const char *loc) {
    volt_dprintf(2, "%s: panic: index %zu out of bounds (len %zu)\n", loc, i, len);
    volt_exit(101);
}

/* Checked integer arithmetic (debug builds): the result, or a panic at loc when it overflows.
   volt_add_i32(a, b, "file.volt:3:5") and so on, for every integer type. */
#define VOLT_CHECKED(N, T) \
    static inline T volt_add_##N(T a, T b, const char *loc) { T r; if (__builtin_add_overflow(a, b, &r)) volt_panic("integer overflow", loc); return r; } \
    static inline T volt_sub_##N(T a, T b, const char *loc) { T r; if (__builtin_sub_overflow(a, b, &r)) volt_panic("integer overflow", loc); return r; } \
    static inline T volt_mul_##N(T a, T b, const char *loc) { T r; if (__builtin_mul_overflow(a, b, &r)) volt_panic("integer overflow", loc); return r; }
VOLT_CHECKED(i8, int8_t) VOLT_CHECKED(i16, int16_t) VOLT_CHECKED(i32, int32_t) VOLT_CHECKED(i64, int64_t)
VOLT_CHECKED(i128, __int128) VOLT_CHECKED(isize, ptrdiff_t)
VOLT_CHECKED(u8, uint8_t) VOLT_CHECKED(u16, uint16_t) VOLT_CHECKED(u32, uint32_t) VOLT_CHECKED(u64, uint64_t)
VOLT_CHECKED(u128, unsigned __int128) VOLT_CHECKED(usize, size_t)
/* Atomics for libraries (std::thread binds them with @intrinsic): sequentially consistent load, store,
   swap, add (giving the old value) and compare-and-swap on 32- and 64-bit words */
#define VOLT_ATOMICS(N, T) \
    VOLT_RT_LINKAGE T volt_rt_atomic_load##N(T *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); } \
    VOLT_RT_LINKAGE void volt_rt_atomic_store##N(T *p, T v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); } \
    VOLT_RT_LINKAGE T volt_rt_atomic_swap##N(T *p, T v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); } \
    VOLT_RT_LINKAGE T volt_rt_atomic_add##N(T *p, T v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); } \
    VOLT_RT_LINKAGE bool volt_rt_atomic_cas##N(T *p, T expected, T desired) { \
        return __atomic_compare_exchange_n(p, &expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); \
    }
VOLT_ATOMICS(32, int32_t) VOLT_ATOMICS(64, int64_t)
/* The system and CPU this program was compiled for, by the C compiler's own macros (std::process
   binds them). The names match what the compilers give @cfg("os") and @cfg("arch") */
VOLT_RT_LINKAGE volt_str volt_rt_os(void) {
#if defined(_WIN32)
    return (volt_str){ (const uint8_t *)"windows", 7 };
#elif defined(__APPLE__)
    return (volt_str){ (const uint8_t *)"macos", 5 };
#elif defined(__linux__)
    return (volt_str){ (const uint8_t *)"linux", 5 };
#elif defined(__FreeBSD__)
    return (volt_str){ (const uint8_t *)"freebsd", 7 };
#else
    return (volt_str){ (const uint8_t *)"unknown", 7 };
#endif
}
VOLT_RT_LINKAGE volt_str volt_rt_arch(void) {
#if defined(__x86_64__) || defined(_M_X64)
    return (volt_str){ (const uint8_t *)"x86_64", 6 };
#elif defined(__aarch64__) || defined(_M_ARM64)
    return (volt_str){ (const uint8_t *)"aarch64", 7 };
#elif defined(__riscv) && __riscv_xlen == 64
    return (volt_str){ (const uint8_t *)"riscv64", 7 };
#elif defined(__i386__) || defined(_M_IX86)
    return (volt_str){ (const uint8_t *)"x86", 3 };
#elif defined(__arm__) || defined(_M_ARM)
    return (volt_str){ (const uint8_t *)"arm", 3 };
#else
    return (volt_str){ (const uint8_t *)"unknown", 7 };
#endif
}
VOLT_RT_LINKAGE bool volt_str_eq(volt_str a, volt_str b) {
    return a.len == b.len && (a.len == 0 || volt_memcmp(a.ptr, b.ptr, a.len) == 0);
}
/* Where formatted text goes: write(ctx, text). volt_stdout() and volt_stderr() are the program's
   streams (stdout buffered, stderr not); std::write and std::format make one around a writer, with a
   compiler-made function that calls the writer's write_str */
typedef struct volt_sink { void (*write)(void *ctx, volt_str s); void *ctx; } volt_sink;
VOLT_RT_LINKAGE void volt_to_stdout(void *ctx, volt_str s) { (void)ctx; volt_printf("%.*s", (int)s.len, (const char *)s.ptr); }
VOLT_RT_LINKAGE void volt_to_stderr(void *ctx, volt_str s) { (void)ctx; volt_dprintf(2, "%.*s", (int)s.len, (const char *)s.ptr); }
VOLT_RT_LINKAGE volt_sink *volt_stdout(void) { static volt_sink s = { volt_to_stdout, 0 }; return &s; }
VOLT_RT_LINKAGE volt_sink *volt_stderr(void) { static volt_sink s = { volt_to_stderr, 0 }; return &s; }
/* printf-style text to a sink; the streams take it straight, a writer gets it in one piece */
VOLT_RT_LINKAGE void volt_out(const volt_sink *s, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (s->write == volt_to_stdout) {
        volt_vprintf(fmt, ap);
    } else if (s->write == volt_to_stderr) {
        volt_vdprintf(2, fmt, ap);
    } else {
        char buf[256];
        va_list again;
        va_copy(again, ap);
        int n = volt_vsnprintf(buf, sizeof buf, fmt, ap);
        if (n >= 0 && (size_t)n < sizeof buf) {
            s->write(s->ctx, (volt_str){ (const uint8_t *)buf, (size_t)n });
        } else if (n >= 0) {
            char *big = volt_malloc((size_t)n + 1);
            if (big) {
                volt_vsnprintf(big, (size_t)n + 1, fmt, again);
                s->write(s->ctx, (volt_str){ (const uint8_t *)big, (size_t)n });
                volt_free(big);
            }
        }
        va_end(again);
    }
    va_end(ap);
}
VOLT_RT_LINKAGE void volt_put(const volt_sink *s, const char *p, size_t n) {
    if (n) s->write(s->ctx, (volt_str){ (const uint8_t *)p, n });
}
VOLT_RT_LINKAGE void volt_print_str(const volt_sink *s, volt_str t) { volt_out(s, "%.*s", (int)t.len, (const char *)t.ptr); }
VOLT_RT_LINKAGE void volt_print_u128(const volt_sink *s, unsigned __int128 v) {
    char buf[40];
    int i = 39;
    buf[i] = 0;
    do { buf[--i] = '0' + (int)(v % 10); v /= 10; } while (v);
    volt_out(s, "%s", buf + i);
}
VOLT_RT_LINKAGE void volt_print_i128(const volt_sink *s, __int128 v) {
    if (v < 0) { volt_out(s, "-"); volt_print_u128(s, -(unsigned __int128)v); }
    else volt_print_u128(s, (unsigned __int128)v);
}
/* A float as the shortest text that reads back as the same value (as a float for f32): %.Ng for
   the smallest N. %g switches to an exponent once it's at least N (1500 at N = 2 is 1.5e+03), so
   below 1e16 the digits are widened to print it plainly */
VOLT_RT_LINKAGE void volt_fmt_float(char *buf, size_t size, double v, int max_digits, bool f32) {
    if (v != v) { volt_snprintf(buf, size, "nan"); return; } /* not printf's -nan: a NaN's sign bit depends on how it was made */
    int p = 1;
    for (; p < max_digits; p++) {
        volt_snprintf(buf, size, "%.*g", p, v);
        double back = volt_strtod(buf, 0);
        if (f32 ? (float)back == (float)v : back == v) break;
    }
    volt_snprintf(buf, size, "%.*g", p, v);
    const char *e = buf;
    while (*e && *e != 'e') e++;
    if (*e && e[1] == '+') {
        int x = 0;
        for (const char *d = e + 2; *d >= '0' && *d <= '9'; d++) x = x * 10 + (*d - '0');
        if (x >= p && x < 16) volt_snprintf(buf, size, "%.*g", x + 1, v);
    }
}
VOLT_RT_LINKAGE void volt_print_f64(const volt_sink *s, double v) {
    char buf[48];
    volt_fmt_float(buf, sizeof buf, v, 17, false);
    volt_out(s, "%s", buf);
}
VOLT_RT_LINKAGE void volt_print_f32(const volt_sink *s, float v) {
    char buf[48];
    volt_fmt_float(buf, sizeof buf, v, 9, true);
    volt_out(s, "%s", buf);
}

/* {:spec}: [[fill]align][sign][#][0][width][.precision][type]. flags: 1 '+', 2 '#', 4 '0'; align
   '<', '>', '^' or 0 (numbers go right, text left); width and prec -1 when not given; type 0 or
   one of x X b o e E c. Each value formats into a buffer, then pads: the sign or 0x prefix comes
   before zero padding, and widths count characters (UTF-8), not bytes */
#define VOLT_F_PLUS 1
#define VOLT_F_ALT 2
#define VOLT_F_ZERO 4
VOLT_RT_LINKAGE size_t volt_utf8_count(const char *p, size_t n) {
    size_t c = 0;
    for (size_t i = 0; i < n; i++) c += ((uint8_t)p[i] & 0xC0) != 0x80;
    return c;
}
VOLT_RT_LINKAGE size_t volt_utf8_put(char *out, uint32_t cp) {
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) cp = 0xFFFD; /* not a character: U+FFFD */
    if (cp < 0x80) { out[0] = (char)cp; return 1; }
    if (cp < 0x800) { out[0] = (char)(0xC0 | cp >> 6); out[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
    if (cp < 0x10000) { out[0] = (char)(0xE0 | cp >> 12); out[1] = (char)(0x80 | (cp >> 6 & 0x3F)); out[2] = (char)(0x80 | (cp & 0x3F)); return 3; }
    out[0] = (char)(0xF0 | cp >> 18); out[1] = (char)(0x80 | (cp >> 12 & 0x3F)); out[2] = (char)(0x80 | (cp >> 6 & 0x3F)); out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}
VOLT_RT_LINKAGE void volt_fill(const volt_sink *s, uint32_t fill, size_t n) {
    char f[4], chunk[64];
    size_t k = volt_utf8_put(f, fill), per = sizeof chunk / k;
    for (size_t i = 0; i < per; i++) volt_memcpy(chunk + i * k, f, k);
    while (n) {
        size_t now = n < per ? n : per;
        volt_put(s, chunk, now * k);
        n -= now;
    }
}
/* prefix (a sign, 0x...) and body, padded to width */
VOLT_RT_LINKAGE void volt_pad(const volt_sink *s, uint32_t fill, int align, int flags, int width, bool numeric,
                              const char *pre, size_t pre_n, const char *body, size_t n) {
    size_t have = volt_utf8_count(pre, pre_n) + volt_utf8_count(body, n);
    size_t pad = width > 0 && (size_t)width > have ? (size_t)width - have : 0;
    if (pad && numeric && (flags & VOLT_F_ZERO) && !align) {
        volt_put(s, pre, pre_n);
        volt_fill(s, '0', pad);
        volt_put(s, body, n);
        return;
    }
    if (!align) align = numeric ? '>' : '<';
    size_t left = align == '<' ? 0 : align == '>' ? pad : pad / 2;
    volt_fill(s, fill, left);
    volt_put(s, pre, pre_n);
    volt_put(s, body, n);
    volt_fill(s, fill, pad - left);
}
VOLT_RT_LINKAGE void volt_fmt_text(const volt_sink *s, volt_str t, uint32_t fill, int align, int flags, int width, int prec) {
    size_t n = t.len;
    if (prec >= 0) {
        /* keep prec characters */
        size_t chars = 0, i = 0;
        for (; i < t.len; i++) {
            if ((t.ptr[i] & 0xC0) != 0x80) {
                if (chars == (size_t)prec) break;
                chars++;
            }
        }
        n = i;
    }
    volt_pad(s, fill, align, flags, width, false, "", 0, (const char *)t.ptr, n);
}
VOLT_RT_LINKAGE void volt_fmt_c(const volt_sink *s, uint32_t cp, uint32_t fill, int align, int flags, int width) {
    char b[4];
    size_t n = volt_utf8_put(b, cp);
    volt_pad(s, fill, align, flags, width, false, "", 0, b, n);
}
VOLT_RT_LINKAGE void volt_fmt_u(const volt_sink *s, unsigned __int128 v, int neg, uint32_t fill, int align, int flags, int width, int type) {
    if (type == 'c') { volt_fmt_c(s, (uint32_t)v, fill, align, flags, width); return; }
    unsigned base = type == 'x' || type == 'X' ? 16 : type == 'b' ? 2 : type == 'o' ? 8 : 10;
    const char *digits = type == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
    char buf[130];
    int i = sizeof buf;
    do { buf[--i] = digits[(int)(v % base)]; v /= base; } while (v);
    char pre[4];
    size_t pn = 0;
    if (neg) pre[pn++] = '-';
    else if (flags & VOLT_F_PLUS) pre[pn++] = '+';
    if ((flags & VOLT_F_ALT) && base != 10) {
        pre[pn++] = '0';
        pre[pn++] = base == 16 ? 'x' : base == 2 ? 'b' : 'o';
    }
    volt_pad(s, fill, align, flags, width, true, pre, pn, buf + i, sizeof buf - (size_t)i);
}
/* a signed integer of `bits` bits: decimal with its sign; x, b and o show its two's complement */
VOLT_RT_LINKAGE void volt_fmt_i(const volt_sink *s, __int128 v, int bits, uint32_t fill, int align, int flags, int width, int type) {
    if (type == 'x' || type == 'X' || type == 'b' || type == 'o') {
        unsigned __int128 u = (unsigned __int128)v;
        if (bits < 128) u &= (((unsigned __int128)1) << bits) - 1;
        volt_fmt_u(s, u, 0, fill, align, flags, width, type);
    } else if (v < 0 && type != 'c') {
        volt_fmt_u(s, -(unsigned __int128)v, 1, fill, align, flags, width, type);
    } else {
        volt_fmt_u(s, (unsigned __int128)v, 0, fill, align, flags, width, type);
    }
}
/* e / E: the mantissa (shortest round trip, or prec digits after the point), then e and the
   exponent without + or leading zeros: 1.5e3, 1.2e-4. buf has room for prec + 32 bytes */
VOLT_RT_LINKAGE void volt_fmt_exp(char *buf, size_t size, double v, int prec, bool f32, bool upper) {
    int p = prec;
    if (p < 0) {
        for (p = 0; p < 17; p++) {
            volt_snprintf(buf, size, "%.*e", p, v);
            double back = volt_strtod(buf, 0);
            if (f32 ? (float)back == (float)v : back == v) break;
        }
    }
    volt_snprintf(buf, size, "%.*e", p, v);
    char *e = buf;
    while (*e && *e != 'e') e++;
    if (!*e) return; /* inf, nan */
    char *d = e + 1;
    bool minus = *d == '-';
    if (*d == '+' || *d == '-') d++;
    while (*d == '0' && d[1]) d++;
    char *w = e;
    *w++ = upper ? 'E' : 'e';
    if (minus) *w++ = '-';
    while (*d) *w++ = *d++;
    *w = 0;
}
VOLT_RT_LINKAGE void volt_fmt_f(const volt_sink *s, double v, int f32, uint32_t fill, int align, int flags, int width, int prec, int type) {
    /* %.Nf of a big double with a big N, or %.Ne, can be long: on the heap past the stack buffer */
    char small[400];
    size_t need = (prec > 0 ? (size_t)prec : 0) + 340;
    char *buf = need <= sizeof small ? small : volt_malloc(need);
    if (!buf) return;
    if (v != v) volt_snprintf(buf, need, "nan"); /* whatever its sign bit, as volt_fmt_float */
    else if (type == 'e' || type == 'E') volt_fmt_exp(buf, need, v, prec, f32, type == 'E');
    else if (prec >= 0) volt_snprintf(buf, need, "%.*f", prec, v);
    else volt_fmt_float(buf, need, v, f32 ? 9 : 17, f32);
    const char *body = buf;
    char pre[1];
    size_t pn = 0;
    if (*body == '-') { pre[pn++] = '-'; body++; }
    else if (flags & VOLT_F_PLUS) pre[pn++] = '+';
    volt_pad(s, fill, align, flags, width, true, pre, pn, body, volt_strlen(body));
    if (buf != small) volt_free(buf);
}
VOLT_RT_LINKAGE void volt_fmt_cstr(const volt_sink *s, const char *c, uint32_t fill, int align, int flags, int width, int prec) {
    volt_fmt_text(s, (volt_str){ (const uint8_t *)c, volt_strlen(c) }, fill, align, flags, width, prec);
}
VOLT_RT_LINKAGE void volt_fmt_bool(const volt_sink *s, int b, uint32_t fill, int align, int flags, int width, int prec) {
    volt_fmt_text(s, b ? (volt_str){ (const uint8_t *)"true", 4 } : (volt_str){ (const uint8_t *)"false", 5 }, fill, align, flags, width, prec);
}

/* The runtime (runtime/runtime.h): allocation (libraries bind it with @intrinsic) and the program's
   arguments. Defined once, in the program's own C unit; prebuilt libraries only call it. */
void *volt_rt_malloc(size_t n);
void volt_rt_free(void *p);
void *volt_rt_realloc(void *p, size_t n);
extern size_t volt_live_allocs;
extern int volt_argc;
extern char **volt_argv;
int volt_rt_argc(void);
volt_str volt_rt_arg(int i);
/* threads (std::thread binds these with @intrinsic): see runtime.h */
int volt_rt_thread_start(void *job, uint64_t *handle);
void volt_rt_thread_join(uint64_t handle);
void volt_rt_thread_yield(void);
void volt_rt_wait(int32_t *word, int32_t expected);
void volt_rt_wake(int32_t *word, bool all);
/* held around each print statement's output to the program's streams */
void volt_lock_out(void);
void volt_unlock_out(void);
