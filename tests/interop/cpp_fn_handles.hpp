// function pointers whose signature has a class Volt holds by handle, a T&& or a std::string&
// (cpp_fn_handles.volt): a named Volt fn, which C++ calls through a thunk made for that fn
#pragma once
#include <string>

namespace fh {
// held by handle (a std::string member)
class Name {
  public:
    explicit Name(const char *s) : s_(s) {}
    int size() const { return (int)s_.size(); }
    void set(const char *s) { s_ = s; }
    std::string text() const { return s_; }
  private:
    std::string s_;
};

inline int apply(int (*f)(const Name &), const char *s) { Name n(s); return f(n); }
inline int moved(int (*f)(Name &&)) { return f(Name("moved")); }
inline std::string rename(void (*f)(Name &, int), const char *s) {
    Name n(s);
    f(n, 2);
    return n.text();
}
inline std::string shouted(void (*f)(std::string &), const char *s) {
    std::string t(s);
    f(t);
    return t;
}
inline int counted(void (*f)(const Name &, int &), const char *s) {
    Name n(s);
    int c = 1;
    f(n, c);
    return c;
}
// C++ keeps the pointer and calls it later
static int (*kept_fn)(const Name &) = nullptr;
inline void keep(int (*f)(const Name &)) { kept_fn = f; }
inline int call_kept(const char *s) { Name n(s); return kept_fn(n); }
}
