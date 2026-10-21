#pragma once
#include <cstddef>
#include <cstdio>
// calls the function it's given as snprintf is called (the header's own snprintf takes a char *)
template <class F> int fill(F f, unsigned char *b, std::size_t n, int x) { return f(b, n, "%d!", x); }
