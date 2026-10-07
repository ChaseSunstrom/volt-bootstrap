// A C++ header a VM script imports (tests/embed/host_imports.c): an inline function over a
// std::vector and a class held by handle
#pragma once
#include <string>
#include <vector>

namespace vm {
inline int total(const std::vector<int> &v) {
    int s = 0;
    for (int x : v) s += x;
    return s;
}
class Tally {
  public:
    void add(int x) { n_ += x; log_.push_back(std::to_string(x)); }
    int value() const { return n_; }

  private:
    int n_ = 0;
    std::vector<std::string> log_;
};
}
