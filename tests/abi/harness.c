/* The C side of round.volt, freestanding (no libc, raw Linux syscalls): calls Volt's v_ fns with
   each shape and checks what comes back, then has Volt call the c_ fns here, prints what came back
   wrong and exits with how many did. tests/abi.rs builds it for aarch64 and runs it under qemu */
typedef struct { unsigned char a, b, c; } s3;
typedef struct { int a, b, c; } s12;
typedef struct { long long a, b; } s16;
typedef struct { long long a, b, c; } s24;
typedef struct { float x, y, z; } hf3;
typedef struct { double a, b, c, d; } hd4;
typedef struct { float a, b; } pair;
typedef struct { pair p; float c[2]; } nest;
typedef struct { float f; int i; } mix;
typedef struct { __int128 a; } al16;

s3 v_s3(s3);
s12 v_s12(s12);
s16 v_s16(s16);
s24 v_s24(s24);
hf3 v_hf3(hf3);
hd4 v_hd4(hd4);
nest v_nest(nest);
mix v_mix(mix);
al16 v_al16(al16);
int v_ints(signed char, unsigned short);
double v_many(long long, long long, long long, long long, long long, long long, long long, long long, s12, double, double, double, double, double, double, double, double, hf3, nest, s24);
int volt_calls_c(void);

s3 c_s3(s3 x) { return (s3){ x.a + 1, x.b + 1, x.c + 1 }; }
s12 c_s12(s12 x) { return (s12){ x.a + 1, x.b + 1, x.c + 1 }; }
s16 c_s16(s16 x) { return (s16){ x.a + 1, x.b + 1 }; }
s24 c_s24(s24 x) { return (s24){ x.a + 1, x.b + 1, x.c + 1 }; }
hf3 c_hf3(hf3 x) { return (hf3){ x.x + 1, x.y + 1, x.z + 1 }; }
hd4 c_hd4(hd4 x) { return (hd4){ x.a + 1, x.b + 1, x.c + 1, x.d + 1 }; }
nest c_nest(nest x) { return (nest){ { x.p.a + 1, x.p.b + 1 }, { x.c[0] + 1, x.c[1] + 1 } }; }
mix c_mix(mix x) { return (mix){ x.f + 1, x.i + 1 }; }
al16 c_al16(al16 x) { return (al16){ x.a + 1 }; }
int c_ints(signed char a, unsigned short b) { return a * 100000 + b; }
double c_many(long long a, long long b, long long c, long long d, long long e, long long f, long long g, long long h, s12 x, double d1, double d2, double d3, double d4, double d5, double d6, double d7, double d8, hf3 y, nest n, s24 big) {
    long long ints = a + b + c + d + e + f + g + h + x.a + x.b + x.c + big.a + big.b + big.c;
    double fls = d1 + d2 + d3 + d4 + d5 + d6 + d7 + d8 + (double)(y.x + y.y + y.z + n.p.a + n.p.b + n.c[0] + n.c[1]);
    return (double)ints * 1000.0 + fls;
}

/* what the compilers may call for struct copies */
void *memcpy(void *d, const void *s, unsigned long n) {
    for (unsigned long i = 0; i < n; i++) ((char *)d)[i] = ((const char *)s)[i];
    return d;
}
void *memset(void *d, int c, unsigned long n) {
    for (unsigned long i = 0; i < n; i++) ((char *)d)[i] = (char)c;
    return d;
}

static long sys(long n, long a, long b, long c) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static int bad;
static void check(int ok, const char *what) {
    if (ok) return;
    long n = 0;
    while (what[n]) n++;
    sys(64, 1, (long)what, n);
    sys(64, 1, (long)"\n", 1);
    bad++;
}

void _start(void) {
    s3 a = v_s3((s3){ 1, 2, 3 });
    check(a.a == 2 && a.b == 3 && a.c == 4, "v_s3");
    s12 b = v_s12((s12){ 1, 2, 3 });
    check(b.a == 2 && b.b == 3 && b.c == 4, "v_s12");
    s16 c = v_s16((s16){ 1, 2 });
    check(c.a == 2 && c.b == 3, "v_s16");
    s24 d = v_s24((s24){ 1, 2, 3 });
    check(d.a == 2 && d.b == 3 && d.c == 4, "v_s24");
    hf3 e = v_hf3((hf3){ 1.5f, 2.5f, 3.5f });
    check(e.x == 2.5f && e.y == 3.5f && e.z == 4.5f, "v_hf3");
    hd4 f = v_hd4((hd4){ 1.5, 2.5, 3.5, 4.5 });
    check(f.a == 2.5 && f.b == 3.5 && f.c == 4.5 && f.d == 5.5, "v_hd4");
    nest g = v_nest((nest){ { 1.5f, 2.5f }, { 3.5f, 4.5f } });
    check(g.p.a == 2.5f && g.p.b == 3.5f && g.c[0] == 4.5f && g.c[1] == 5.5f, "v_nest");
    mix h = v_mix((mix){ 1.5f, 2 });
    check(h.f == 2.5f && h.i == 3, "v_mix");
    __int128 big = ((__int128)1 << 100) + 5;
    al16 i = v_al16((al16){ big });
    check(i.a == big + 1, "v_al16");
    check(v_ints(-3, 65535) == -234465, "v_ints");
    double m = v_many(1, 2, 3, 4, 5, 6, 7, 8, (s12){ 9, 10, 11 }, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, (hf3){ 0.25f, 0.5f, 0.75f }, (nest){ { 1, 2 }, { 3, 4 } }, (s24){ 12, 13, 14 });
    check(m == 105043.5, "v_many");
    int back = volt_calls_c();
    check(back == 0, "volt_calls_c");
    if (!bad) sys(64, 1, (long)"ok\n", 3);
    sys(94, bad, 0, 0);
    for (;;) {}
}
