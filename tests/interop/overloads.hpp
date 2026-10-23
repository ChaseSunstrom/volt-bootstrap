// Overloads Volt can't tell apart (cpp_overloads.volt): long and long long are both i64, char and
// signed char both i8, a const method's this is a non-const one's. The first declared keeps the
// name; the rest come through named for their parameter types, called exactly
#pragma once
#include <string>
#include <utility>
namespace ov {
inline int which(long) { return 1; }
inline int which(long long) { return 2; }
// char last: it's signed char's or unsigned char's twin depending on the target, so it's the one
// that collides on every target
inline int letter(signed char) { return 2; }
inline int letter(unsigned char) { return 3; }
inline int letter(char) { return 1; }
inline int f(long x) { return (int)x; }
inline int f(long long x, int n = 0) { return (int)x * 10 + n; }
// the full form collides (h_long_long_int_int), the shorter one doesn't (h, with its C++ comment)
inline int h(long x, int a, int b) { return 1; }
inline int h(long long x, int a, int b = 0) { return 2; }
// a class template held by handle: its members are worked out per use, where an && method (const
// && too) consumes the handle as a declared one does: C++ moves from the object (take empties it),
// or from a copy when the handle only borrows it
template <class T>
class Holder {
    T v_;
  public:
    Holder(T v) : v_(v) {}
    T take() && { T r = v_; v_ = T(); return r; }
    T look() const && { return v_; }
    T peek() const & { return v_; }
};
// a borrowed handle (a reference result)
inline Holder<int> &shelf() {
    static Holder<int> h(5);
    return h;
}
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
    int operator()(int k) { return x + k; }
    int operator()(int k) const { return x - k; }
    // the const one first: the other is get_nonconst
    int peek() const { return 1; }
    int peek() { return 2; }
};
// an && method consumes the object (C++ moves from it); on a borrowed handle, from a copy
class Box {
  public:
    explicit Box(int n) : s_(std::to_string(n)) {}
    virtual ~Box() {}
    std::string open() & { return "lref " + s_; }
    std::string open() && { std::string r = "rref " + s_; s_ = "gone"; return r; }
    std::string peek() const { return s_; }
    // && and const && (size, size_const_rref)
    int size() && { return 1; }
    int size() const && { return 2; }
  private:
    std::string s_;
};
class Crate : public Box {
  public:
    explicit Crate(int n) : Box(n) {}
};
// neither copied nor moved: an && method runs on an owned handle's object, the handle consumed
// (its object deleted once, after the call: dropped counts them); a borrowed handle has no object
// to hand C++ (no copy), so the call stops the program. A const && method runs in place
class Pinned {
  public:
    explicit Pinned(int n) : n_(n) {}
    Pinned(const Pinned &) = delete;
    Pinned(Pinned &&) = delete;
    ~Pinned() { ++drops(); }
    int take() && { int r = n_; n_ = 0; return r; }
    int take() const && { return n_ + 100; }
    int peek() const { return n_; }
    static int dropped() { return drops(); }
  private:
    static int &drops() { static int n = 0; return n; }
    int n_;
};
class PinnedCrate : public Pinned {
  public:
    explicit PinnedCrate(int n) : Pinned(n) {}
};
// an abstract class (neither copied nor moved, by clang's account): its && method runs in place
// on the object, a borrowed handle's (as_Shape()) too, as before
class Shape {
  public:
    virtual ~Shape() {}
    virtual int sides() const = 0;
    int spend() && { return sides() * 10; }
};
class Square : public Shape {
  public:
    explicit Square(int n) : n_(n) {}
    int sides() const { return n_; }
  private:
    int n_;
};
// a borrowed handle (a reference result)
inline Pinned &pinned_shelf() {
    static Pinned p(41);
    return p;
}
// a borrowed PinnedCrate, whose && take() is Pinned's (inherited: worked out per use)
inline PinnedCrate &crate_shelf() {
    static PinnedCrate c(9);
    return c;
}
}
// a real function with the name the alias would take keeps it, though declared after
namespace taken {
inline int which(long) { return 1; }
inline int which(long long) { return 2; }
inline int which_long_long(long long) { return 3; }
}
// ...also one in a block of the namespace opened again after the alias was written: the alias is
// which_long_long_2
namespace again {
inline int which(long) { return 1; }
inline int which(long long) { return 2; }
}
namespace again {
inline int which_long_long(long long) { return 3; }
}
