#pragma once
// templates whose parameter deduces the function given to them
template <class F> int apply(F f) { return f(); }
template <class F> int apply1(F f, int x) { return f(x); }
// an overload taking a function pointer of one signature beside the template: a fn of that
// signature picks it, any other the template
inline int pick(int (*f)(int)) { return f(1) + 100; }
template <class F> int pick(F f) { return f(); }
