// calls worked out per use (templates) taking arrays of enums or of a class held by handle by
// reference, nested std::vector<bool>s and std::vectors of a class, arrays of arrays, and a pointer
// and count of a Volt struct's mirrors, and giving back a std::vector of a class (cpp_peruse5.volt)
#pragma once
#include <string>
#include <vector>

namespace p5 {
enum class Mode : int { A, B, C };
// held by handle (a std::string member)
class Widget {
  public:
    explicit Widget(const char *n) : name_(n) {}
    std::string name() const { return name_; }
    void rename(const char *n) { name_ = n; }
  private:
    std::string name_;
};

template <class T> int modes(T (&m)[3]) { int s = 0; for (T x : m) s = s * 10 + (int)x; m[0] = T::C; return s; }
template <class T> std::string widgets(T (&w)[2]) { std::string s = w[0].name() + w[1].name(); w[1].rename("z"); return s; }
template <class T> int bits(const std::vector<std::vector<T>> &v) { int n = 0; for (auto &r : v) for (bool b : r) n += b; return n; }
template <class T> std::string names(const std::vector<T> &v) { std::string s; for (auto &w : v) s += w.name(); return s; }
template <class T> int grid(T (&g)[2][3]) { int s = 0; for (auto &r : g) for (T x : r) s += x; g[1][2] = 9; return s; }
template <class T> T last(const T *p, int n) { return p[n - 1]; }
template <class T> std::vector<T> make_widgets(int n) { std::vector<T> v; for (int i = 0; i < n; i++) v.emplace_back(i ? "b" : "a"); return v; }
}
