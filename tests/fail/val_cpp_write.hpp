#include <string>

namespace vw {
template <typename S> void fill(S& s) { s += "!"; }
template <typename S> int look(const S& s) { return (int)s.size(); }
}
// an S& beside a const S&: C++ runs S& for a string Volt can change (val_cpp_write_both, _try)
namespace vw {
template <typename S> int pick(S &s) { s += "?"; return 1; }
template <typename S> int pick(const S &) { return 2; }
}
