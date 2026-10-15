// Ranges whose iterators Volt can't hold in its own words: one holding a std::shared_ptr, a move-only
// one (each counts its live iterators) and an over-aligned one (cpp_ranges2.volt)
#pragma once
#include <memory>

namespace r2 {
inline int &live() {
    static int n = 0;
    return n;
}
struct counted {
    counted() { ++live(); }
    ~counted() { --live(); }
};

// its iterators share a counted, so they aren't trivially copyable or destructible
class shared_range {
  public:
    explicit shared_range(int n) : n_(n) {}
    ~shared_range() {}
    struct iterator {
        std::shared_ptr<counted> c;
        int i;
        int operator*() const { return i * 10; }
        iterator &operator++() {
            ++i;
            return *this;
        }
        bool operator==(const iterator &o) const { return i == o.i; }
        bool operator!=(const iterator &o) const { return i != o.i; }
    };
    iterator begin() const {
        iterator it = {std::make_shared<counted>(), 0};
        return it;
    }
    iterator end() const {
        iterator it = {std::make_shared<counted>(), n_};
        return it;
    }

  private:
    int n_;
};

// its iterators own a counted: they can be moved, not copied
class move_range {
  public:
    explicit move_range(int n) : n_(n) {}
    ~move_range() {}
    struct iterator {
        std::unique_ptr<counted> c;
        int i;
        explicit iterator(int at) : c(new counted), i(at) {}
        iterator(iterator &&) = default;
        iterator &operator=(iterator &&) = default;
        int operator*() const { return i + 1; }
        iterator &operator++() {
            ++i;
            return *this;
        }
        bool operator==(const iterator &o) const { return i == o.i; }
        bool operator!=(const iterator &o) const { return i != o.i; }
    };
    iterator begin() const { return iterator(0); }
    iterator end() const { return iterator(n_); }

  private:
    int n_;
};

// its iterators are aligned past 8 (C++ holds them with an aligned new: C++17)
class wide_range {
  public:
    explicit wide_range(int n) : n_(n) {}
    ~wide_range() {}
    struct iterator {
        alignas(32) int i;
        ~iterator() {}
        int operator*() const { return i * i; }
        iterator &operator++() {
            ++i;
            return *this;
        }
        bool operator==(const iterator &o) const { return i == o.i; }
        bool operator!=(const iterator &o) const { return i != o.i; }
    };
    iterator begin() const {
        iterator it = {0};
        return it;
    }
    iterator end() const {
        iterator it = {n_};
        return it;
    }

  private:
    int n_;
};
}
