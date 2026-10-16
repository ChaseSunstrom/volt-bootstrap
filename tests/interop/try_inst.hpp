// a class template's instance made while checking, whose methods' try_ forms appear only then: the
// import has no throwing declared function (each is noexcept), so only they need cpp_error
// (cpp_try_inst.volt)
#include <stdexcept>
namespace ti {
template <class T> class Box {
    T v_;
  public:
    explicit Box(T v) noexcept : v_(v) {}
    T get(int k) const {
        if (k < 0) throw std::range_error("neg");
        return v_ + (T)k;
    }
};
inline int plain(int x) noexcept { return x + 1; }
inline Box<int> boxed(int v) noexcept { return Box<int>(v); }
}
