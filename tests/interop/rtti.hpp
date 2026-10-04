// Casts between C++ classes, their dynamic types, and the exceptions C++ throws (cpp_rtti.volt)
#pragma once
#include <new>
#include <stdexcept>
#include <string>

namespace zoo {

class Animal {
public:
    virtual ~Animal() = default;
    virtual std::string sound() const { return "..."; }
    std::string name = "animal";
};

class Named {
public:
    virtual ~Named() = default;
    std::string tag = "named";
};

// a second base, at an offset in the object: a cast moves the pointer
class Dog : public Animal, public Named {
public:
    std::string sound() const override { return "woof"; }
    int tricks = 3;
};

class Cat : public Animal {
public:
    std::string sound() const override { return "meow"; }
};

// a base Volt holds by value, in a class held by handle
struct Size {
    int w = 2, h = 3;
};

struct Boxed : Size {
    std::string label = "box";
};

// Named twice (once privately): no as_Named, the other casts as usual
class Robo : public Dog, private Named {};

inline std::string speak(const Animal& a) { return a.sound(); }
// by value: a borrowed handle's object is copied, not moved from
inline std::string adopt(Animal a) { return a.name + "!"; }
inline std::string tag_of(const Named& n) { return n.tag; }
inline int area(const Size& s) { return s.w * s.h; }

// exceptions of the library's own, one deriving from the other
class zoo_error : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class escaped : public zoo_error {
public:
    using zoo_error::zoo_error;
};

// a std::exception only privately: not one a catch of std::exception takes
class quiet_error : std::exception {};

inline int feed(int n) {
    if (n < 0) throw std::invalid_argument("negative food");
    if (n > 100) throw std::out_of_range("too much food");
    if (n == 7) throw escaped("the tiger escaped");
    if (n == 8) throw zoo_error("closed");
    if (n == 9) throw 42;
    if (n == 10) throw std::bad_alloc();
    if (n == 11) throw std::bad_exception();
    if (n == 12) throw quiet_error();
    return n * 2;
}

}  // namespace zoo
