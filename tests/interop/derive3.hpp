// Subclassing a C++ class from Volt (cpp_derive3.volt): virtual methods taking a std::string&,
// giving back a reference (a number, a laid-out class, a class held by handle), overloads of one
// name, an &-qualified one and private ones (pure, and with C++'s own)
#pragma once
#include <string>

namespace d3 {
struct Pt {
    int x;
    int y;
};

class Item {
  public:
    explicit Item(int v) : v_(v) {}
    int v() const { return v_; }

  private:
    int v_;
    std::string tag_ = "item";
};

class Base {
  public:
    virtual ~Base() = default;
    virtual void fill(std::string &s) { s += "-base"; }
    virtual int &slot() { return n_; }
    virtual Pt &spot() { return pt_; }
    virtual const Item &pick() const { return it_; }
    virtual int draw(int x) { return x; }
    virtual int draw(double x) { return (int)x; }
    virtual int tag() const & { return 1; }
    virtual int gone() && { return 0; }
    int run() { return hook() * 10; }

  private:
    virtual int hook() { return 1; }
    int n_ = 0;
    Pt pt_{0, 0};
    Item it_{3};
};

// its draw(int) hides Base's draw(double), which a Volt type not overriding draw_double still gets
class Mid : public Base {
  public:
    int draw(int x) override { return x * 3; }
};

// a pure virtual taking a std::string&, and a private pure one: Volt can derive from it
class Sink {
  public:
    virtual ~Sink() = default;
    virtual void put(std::string &s) = 0;
    int reveal() { return secret(); }

  private:
    virtual int secret() = 0;
};

// two private virtual methods with C++'s own: a Volt type overrides either, both or neither
class Two {
  public:
    virtual ~Two() = default;
    int both() { return a() * 10 + b(); }

  private:
    virtual int a() { return 1; }
    virtual int b() { return 2; }
};

// Two's private virtual methods, inherited through a base that isn't public
class Shy : protected Two {
  public:
    int all() { return both(); }
};

inline std::string use_fill(Base &b) {
    std::string s = "x";
    b.fill(s);
    return s;
}
inline int use_slot(Base &b) {
    b.slot() += 5;
    return b.slot();
}
inline int use_spot(Base &b) {
    b.spot().x += 1;
    return b.spot().x * 100 + b.spot().y;
}
inline int use_pick(const Base &b) { return b.pick().v(); }
inline int use_draw(Base &b) { return b.draw(2) * 1000 + b.draw(3.9); }
inline int use_tag(const Base &b) { return b.tag(); }
inline int use_run(Base &b) { return b.run(); }
inline int use_both(Two &t) { return t.both(); }
inline int use_all(Shy &s) { return s.all(); }
inline std::string use_put(Sink &k) {
    std::string s = "in";
    k.put(s);
    return s + "/" + std::to_string(k.reveal());
}
} // namespace d3
