/* C unions sigs.volt imports and sigs.c includes: their members overlap, so a union of one float
   type is an HFA (AAPCS64) and SSE (SysV) as a struct of that float would be */
typedef union { float a; float b; } uf;
typedef union { double a; double b; } ud;
typedef union { struct { float x, y; } p; float a[2]; } uf2;
typedef union { float f; double d; } ufd;
typedef union { float f; int i; } ufi;
typedef struct { uf u; float y; } sfu;
typedef struct { float y; uf u; } sfu2;
/* one member: the member itself where an ABI takes one scalar (clang's WebAssembly) */
typedef union { float f; } u1f;
typedef union { double d; } u1d;
typedef struct { u1f x; } su1;
