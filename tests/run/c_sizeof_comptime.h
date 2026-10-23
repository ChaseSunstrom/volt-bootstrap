/* C structs whose size and alignment Volt knows at compile time (c_sizeof_comptime.volt): plain,
   with a bitfield (padding fields), with an anonymous union (placed by libclang's offsets), packed */
#include <stddef.h>

struct point { int x; double y; char tag; };
struct flags { int a : 3; unsigned b : 5; float f; };
struct either { int kind; union { double d; char c[12]; }; };
struct __attribute__((packed)) tight { char c; int n; short s; };

static inline size_t point_size(void) { return sizeof(struct point); }
static inline size_t point_align(void) { return _Alignof(struct point); }
static inline size_t flags_size(void) { return sizeof(struct flags); }
static inline size_t either_size(void) { return sizeof(struct either); }
static inline size_t either_align(void) { return _Alignof(struct either); }
static inline size_t tight_size(void) { return sizeof(struct tight); }
