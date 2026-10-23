// a std::function parameter taken by value, which C++ keeps (cpp_fn_kept.volt): the Volt closure
// moves in and the std::function owns it
#pragma once
#include <functional>
#include <string>

namespace fk {
class Button {
  public:
    void on_click(std::function<int(int)> f) { cb_ = std::move(f); }
    int click(int n) const { return cb_ ? cb_(n) : -1; }
    void clear() { cb_ = nullptr; }
  private:
    std::function<int(int)> cb_;
};
// kept, then copied: the copies share the closure
inline std::function<int()> &kept() { static std::function<int()> f; return f; }
inline void keep(std::function<int()> f) { kept() = f; }
inline int run_kept() { std::function<int()> g = kept(); int r = g() * 10 + kept()(); kept() = nullptr; return r; }
// only called, not kept: a plain fn and a fn value are lent
inline int apply_now(std::function<int(int)> f, int x) { return f(x); }
}
