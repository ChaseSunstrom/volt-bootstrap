// C++ fields and values (cpp_fields.volt): bit-fields of a class held by value and of one held by
// handle, a std::function field Volt sets (the field keeping the closure), namespace variables C++
// may change, and constants clang can't work out
#pragma once
#include <functional>
#include <string>

namespace fl {
struct Flags {
    unsigned ready : 1;
    unsigned : 2;
    unsigned level : 3;
    int count;
};

enum class Mode : unsigned char { Off, Slow, Fast };

class Device {
  public:
    std::string name = "dev";
    unsigned on : 1;
    Mode mode : 2;
    std::function<int(int)> scale;
    Device() : on(0), mode(Mode::Off) {}
    int apply(int x) const { return scale ? scale(x) : x; }
};

inline int counter = 5;
inline std::string banner = "hello";
inline Device main_device;
inline int next() { return ++counter; }
inline int seed() { return 42; }
const int answer = seed();
const std::string motto = "bits and bytes";
}
