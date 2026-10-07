/* A header a VM script imports (tests/embed/host_imports.c): a static function and a macro, which
   only C compiled for the script defines */
static inline int h_twice(int x) { return 2 * x; }
#define H_MAX(a, b) ((a) > (b) ? (a) : (b))
