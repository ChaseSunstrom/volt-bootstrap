/* a declaration only under a macro the program's C doesn't set, for tests/run/c_wrappers.volt:
   c_hidden_on.h sets it, but this header is included before that one, so its guard keeps the
   declaration out of the program's C */
#ifndef C_HIDDEN_H
#define C_HIDDEN_H
#ifdef C_HIDDEN_ON
long double ld_hidden(long double x);
#endif
static inline long double ld_shown(long double x) { return x + 1; }
#endif
