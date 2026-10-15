// Overloads Volt can't tell apart (cpp_overloads.volt): long and long long are both i64, char and
// signed char both i8, a const method's this is a non-const one's. The first declared keeps the
// name; the rest come through named for their parameter types, called exactly
#pragma once
#include <string>
namespace ov {
inline int which(long) { return 1; }
inline int which(long long) { return 2; }
inline int letter(char) { return 1; }
inline int letter(signed char) { return 2; }
inline int letter(unsigned char) { return 3; }
inline int f(long x) { return (int)x; }
inline int f(long long x, int n = 0) { return (int)x * 10 + n; }
// held by handle (a std::string field)
class Tally {
  public:
    explicit Tally(long n) : n_((int)n), name_("long") {}
    explicit Tally(long long n) : n_((int)n * 2), name_("long long") {}
    int get() { return n_; }
    int get() const { return -n_; }
    int add(long k) { return n_ += (int)k; }
    int add(long long k) { return n_ += 10 * (int)k; }
    std::string name() const { return name_; }
  private:
    int n_;
    std::string name_;
};
// laid out (trivially copyable)
struct Point {
    int x;
    int scaled(long k) const { return x * (int)k; }
    int scaled(long long k) const { return -x * (int)k; }
};
}
// a real function with the name the alias would take keeps it, though declared after
namespace taken {
inline int which(long) { return 1; }
inline int which(long long) { return 2; }
inline int which_long_long(long long) { return 3; }
}
