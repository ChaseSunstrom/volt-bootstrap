/* a struct with a bitfield: Volt imports `before` and `after` but not the bitfield between them */
typedef struct { int before; unsigned flag : 1; int after; } flags;
static inline int flags_after(flags f) { return f.after; }
/* a field whose type Volt can't read (__typeof__): its layout is partial the same way */
typedef struct { int a; __typeof__(1.0) t; int b; } typed;
static inline int typed_b(typed x) { return x.b; }
