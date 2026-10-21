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
}
