/* A C89 header (kept out of Volt's C, in a unit of its own) declaring functions nothing defines:
   one Volt calls through a wrapper (a long double) and one it calls directly; and one it defines */
long double kept_ld_missing(long double x);
int kept_missing(int x);
static int kept_ok(int x) { return x + 1; }
