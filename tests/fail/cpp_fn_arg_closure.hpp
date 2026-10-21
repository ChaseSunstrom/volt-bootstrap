#pragma once
// templates whose parameter deduces the function given to them
template <class F> int apply(F f) { return f(); }
template <class F> int apply1(F f, int x) { return f(x); }
template <class T> T echo(T t) { return t; }
