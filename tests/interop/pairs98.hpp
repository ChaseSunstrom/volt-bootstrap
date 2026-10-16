// Written for C++98 (and read under C++11 too, the same): a std::map and a std::pair in signatures,
// read as a tuple under both; class template instances held by handle (a generic's, and one with a
// number for a parameter), and a class's base reached
#pragma once
#include <map>
#include <string>
#include <utility>
namespace p98 {
inline std::map<int, double> weights() {
    std::map<int, double> m;
    m[2] = 0.5;
    m[1] = 1.25;
    return m;
}
inline std::pair<int, int> div_mod(int a, int b) { return std::make_pair(a / b, a % b); }
inline int sum_pair(std::pair<int, int> p) { return p.first * 10 + p.second; }
class Named {
  public:
    Named() : name_("named") {}
    virtual ~Named() {}
    int id() const { return 7; }

  private:
    std::string name_;
};
template <class T>
class Boxed : public Named {
  public:
    Boxed() : v_() {}
    T get() const { return v_; }
    void set(T v) { v_ = v; }

  private:
    T v_;
};
typedef Boxed<int> IntBox;
// an instance of a template with a number for a parameter (no Volt generic: a handle of its own)
template <int N>
class Fixed : public Named {
  public:
    int size() const { return N; }
};
typedef Fixed<3> Fixed3;
inline Fixed3 fixed3() { return Fixed3(); }
class Labeled : public Named {
  public:
    int mark() const { return 9; }
};
inline IntBox boxed(int v) {
    IntBox b;
    b.set(v);
    return b;
}
}
