// template pairs that differ only in a reference and a value: called with an explicit T both would
// take the same argument, so each wrapper names its own overload
#pragma once

namespace tw {
// T& / T: f(&m) changes m, f_value(5) gets a copy
template <class T> int twin(T &x) { x += 1; return 1; }
template <class T> int twin(T x) { x += 1; return 2; }
// const T& / T, in the other order
template <class T> int peek(T x) { return 20 + (int)x; }
template <class T> int peek(const T &x) { return 10 + (int)x; }
// T a pointer: const T& is T const & (a const pointer), not a pointer to const
template <class T> int deref(const T &p) { return 30 + *p; }
template <class T> int deref(T p) { return 40 + *p; }
// a defaulted trailing argument: only the full forms (a pointer to the function takes every one)
template <class T> int dflt(T &x, int k = 1) { x += k; return 50; }
template <class T> int dflt(T x, int k = 1) { return 60 + k; }
// a static method pair of a class
struct Box {
    template <class T> static int pair(T &x) { x += 10; return 70; }
    template <class T> static int pair(T x) { return 80 + (int)x; }
};
}
