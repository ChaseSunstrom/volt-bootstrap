/* sigs.volt's export fns in C: tests/abi.rs compares how clang lowers these with how voltc lowers
   those, for each host */
typedef struct { unsigned char a; } s1;
typedef struct { unsigned char a, b, c; } s3;
typedef struct { short a; unsigned char b; } s4;
typedef struct { int a, b; } s8;
typedef struct { int a, b, c; } s12;
typedef struct { long long a, b; } s16;
typedef struct { long long a, b, c; } s24;
typedef struct { double x, y; } hd2;
typedef struct { float x, y, z; } hf3;
typedef struct { double a, b, c, d; } hd4;
typedef struct { double a, b, c, d, e; } hd5;
typedef struct { float a, b; } pair;
typedef struct { pair p; float c[2]; } nest;
typedef struct { float f; int i; } mix;
typedef struct { __int128 a; } al16;
typedef struct { float a; double b; } fd;
typedef struct { double x; } hd1;
#if defined(__aarch64__)
/* half and quad floats make HFAs too (long double is a quad only on aarch64 Linux; elsewhere these
   shapes lower another way, through rules this test doesn't cover yet) */
typedef struct { _Float16 a, b; } hh2;
hh2 fhh2(hh2 x) { return x; }
#if !defined(__APPLE__)
typedef struct { long double a, b; } hq2;
hq2 fhq2(hq2 x) { return x; }
#endif
#endif

s1 f1(s1 x) { return x; }
s3 f3(s3 x) { return x; }
s4 f4(s4 x) { return x; }
s8 f8(s8 x) { return x; }
s12 f12(s12 x) { return x; }
s16 f16(s16 x) { return x; }
s24 f24(s24 x) { return x; }
hd1 fh1(hd1 x) { return x; }
hd2 fh2(hd2 x) { return x; }
hf3 fh3(hf3 x) { return x; }
hd4 fh4(hd4 x) { return x; }
hd5 fh5(hd5 x) { return x; }
nest fnest(nest x) { return x; }
mix fmix(mix x) { return x; }
al16 fal16(al16 x) { return x; }
fd ffd(fd x) { return x; }
signed char ints(signed char a, unsigned short b, int c, long long d) { return a; }
__int128 wide(__int128 a) { return a; }
float floats(float a, double b) { return a; }
void edge(long long a, long long b, long long c, __int128 w, s16 x) {}
void many(long long a, long long b, long long c, long long d, long long e, long long f, long long g, s12 x, double d1, double d2, double d3, double d4, double d5, double d6, double d7, hf3 h, nest n, s24 big) {}
