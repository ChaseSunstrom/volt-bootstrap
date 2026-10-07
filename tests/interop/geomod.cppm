// A C++20 named module importing the standard library as a module, for cpp_module.volt: an
// exported namespace of functions and a class; what it doesn't export stays out of the import
module;
export module geomod;
import std;

int hidden_helper(int x) { return x * 3; }

export namespace geo {
int twice(int x) { return 2 * x; }
std::string label(int n) { return std::format("n={}", n); }
class Counter {
  public:
    explicit Counter(int start) : n_(start) {}
    int bump() { return ++n_; }
    int value() const { return n_; }

  private:
    int n_;
    std::vector<int> log_;
};
int triple(int x) { return hidden_helper(x); }
}
