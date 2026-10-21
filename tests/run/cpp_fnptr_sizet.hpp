#pragma once
#include <cstddef>
#include <cstring>
namespace fp {
// a callback type taking std::size_t (libc++'s std::size_t is `using ::size_t`, which libclang may
// show only by its spelling)
using sizer = int (*)(std::size_t);
inline int call_sizer(sizer f, int n) { return f((std::size_t)n * 2); }
inline int count(const char *s) { return s ? (int)std::strlen(s) : -1; }
}
