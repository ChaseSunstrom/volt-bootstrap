// A C++ header two VM scripts import (tests/embed/host_imports.c): it imports the C++ library as a
// module
#pragma once
import std;

namespace vs {
inline int big(int a, int b) { return std::max(a, b); }
}
