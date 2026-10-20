#include <string>

namespace vw {
template <typename S> void fill(S& s) { s += "!"; }
template <typename S> int look(const S& s) { return (int)s.size(); }
}
