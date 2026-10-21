#include <string>
#include <utility>

namespace rr {
// keeps what it's given: C++ moves from an S&&
template <class S> int take(S &&s) { S kept(std::move(s)); return (int)kept.size(); }
}
