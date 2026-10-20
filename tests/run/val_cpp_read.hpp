#include <string>

namespace vr {
template <typename S> void fill(S& s) { s += "!"; }
template <typename S> int look(const S& s) { return (int)s.size(); }
template <typename S> int copy_of(S s) { s += "?"; return (int)s.size(); }
}
