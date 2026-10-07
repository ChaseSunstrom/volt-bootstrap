// C++ exceptions and Volt (cpp_errors.volt): try_ forms of functions returning a class held by
// handle, a reference, an optional and a vector; and an exception thrown by C++ that Volt called
// from a callback, caught by the C++ that called the callback
#pragma once
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace ex {
struct bad_input : std::runtime_error {
    using std::runtime_error::runtime_error;
};

class Box {
  public:
    explicit Box(int v) : v_(v) {
        if (v < 0) throw std::invalid_argument("negative box");
    }
    Box(const Box &) = delete;
    int v() const { return v_; }

  private:
    int v_;
    std::string tag_ = "box";
};

inline std::unique_ptr<Box> make(int v) { return std::make_unique<Box>(v); }

class Store {
  public:
    static int limit(int x) {
        if (x > 9) throw std::out_of_range("over the limit");
        return x;
    }
    int &slot(int i) {
        if (i != 0) throw std::out_of_range("no slot");
        return n_;
    }
    template <class T>
    T as(int x) const {
        if (x < 0) throw bad_input("negative");
        return T(x) / 2;
    }
    Box &at(int i) {
        if (i != 0) throw std::out_of_range("no box " + std::to_string(i));
        return b_;
    }

  private:
    Box b_{1};
    int n_ = 7;
};

template <class A, class B>
struct Pair {
    A a;
    B b;
    Pair(A x, B y) : a(x), b(y) {
        if (x < 0) throw std::domain_error("negative first");
    }
};

// a C++ class Volt subclasses: what its override throws reaches walk
class Visitor {
  public:
    virtual ~Visitor() = default;
    virtual int visit(int x) = 0;
};

inline std::string walk(Visitor &v, int x) {
    try {
        return "walked " + std::to_string(v.visit(x));
    } catch (const bad_input &e) {
        return std::string("walk caught bad_input: ") + e.what();
    }
}

inline std::optional<int> parse(const std::string &s) {
    if (s.empty()) throw bad_input("empty");
    if (s == "x") return std::nullopt;
    return std::stoi(s);
}

inline std::vector<int> range(int n) {
    if (n < 0) throw std::length_error("negative range");
    std::vector<int> v;
    for (int i = 0; i < n; i++) v.push_back(i);
    return v;
}

inline int check(int x) {
    if (x > 3) throw bad_input("too big");
    return x;
}

// calls f, catching what it throws with its own type
inline std::string run(const std::function<int(int)> &f, int x) {
    try {
        return "ok " + std::to_string(f(x));
    } catch (const bad_input &e) {
        return std::string("caught bad_input: ") + e.what();
    } catch (const std::exception &e) {
        return std::string("caught other: ") + e.what();
    }
}
}
