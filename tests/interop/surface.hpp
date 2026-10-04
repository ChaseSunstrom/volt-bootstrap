// The rest of what a C++ header has (cpp_surface.volt): constants, static members, nested classes,
// conversion and assignment operators, T&& results, member templates and std::function
#pragma once
#include <functional>
#include <string>
#include <string_view>
#include <utility>

namespace kit {

constexpr int LIMIT = 42;
constexpr double RATIO = 1.5;
const bool ENABLED = true;
constexpr const char *NAME = "kit \"tools\"";
enum class Level { Low, High };
constexpr Level DEFAULT_LEVEL = Level::High;
int counter_value = 3;  // not const: no Volt val
constexpr double TINY = 1e-9;

// unscoped enums inside classes, with the same names: each class's own
struct Lamp {
    enum Mode { Off, On };
    Mode mode = On;
};
struct Fan {
    enum Mode { Off, Slow };
    Mode mode = Slow;
};

// a conversion in a class template: left out (its type is the template's)
template <class T>
struct Wrap {
    T v;
    operator T() const { return v; }
};

// trivially copyable: Volt holds it by value
struct Counter {
    int n = 0;
    static inline int created = 0;
    static constexpr int MAX = 10;
    struct Step {
        int by = 1;
    };
    explicit operator bool() const { return n != 0; }
    operator int() const { return n; }
    Counter& operator=(int v) {
        n = v;
        return *this;
    }
    template <class T>
    T cast_to() const { return static_cast<T>(n); }
    void advance(Step s) { n += s.by; }
};

// held by handle (a std::string member)
class Registry {
public:
    static inline std::string label = "reg";
    class Entry {
    public:
        std::string key = "k";
        int value = 1;
    };
    Entry first() const { return Entry{}; }
    Entry&& steal() {
        kept.value = 9;
        return std::move(kept);
    }
    template <class T>
    T scaled(T x) const { return x * 2; }

private:
    Entry kept;
};

// a template's T* parameter, and a template instance with a defaulted argument
template <class T>
int deref_or(T* p, T d) {
    return p ? static_cast<int>(*p) : static_cast<int>(d);
}
template <class T, class Tag = void>
struct Holder {
    T value;
};
inline Holder<int> hold(int v) { return Holder<int>{v}; }

// std::function: a Volt fn value in, a C++ callable out
inline int apply(const std::function<int(int)>& f, int x) { return f(x) + 1; }
inline double twice_apply(std::function<double(double)> f, double x) { return f(f(x)); }
inline void each(int n, const std::function<void(int)>& f) {
    for (int i = 0; i < n; i++) f(i);
}
inline bool check(std::function<bool(std::string_view)> f) { return f("abc"); }
inline std::function<int(int)> adder(int k) {
    return [k](int x) { return x + k; };
}
// a function template giving a std::function back
template <class T>
std::function<int(int)> scale_by(T k) {
    return [k](int x) { return x * static_cast<int>(k); };
}
// a std::function field: a getter, no setter (it would keep a Volt closure)
struct Button {
    std::function<int(int)> on = [](int x) { return x; };
};

}  // namespace kit
