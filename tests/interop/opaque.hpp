// C++ types Volt can't lay out, used by value from Volt (held by handle): a class template with
// private state and a base (nlohmann::basic_json's shape), one with virtual methods, a lambda's type
// and a coroutine-style task
#pragma once
#include <cstddef>
#include <map>
#include <string>
namespace op {
struct counted {
    int made = 1;
};

template <class K = std::string>
class doc : public counted {
    std::map<K, int> fields_;
public:
    void set(const K &k, int v) { fields_[k] = v; }
    int get(const K &k) const {
        auto it = fields_.find(k);
        return it == fields_.end() ? -1 : it->second;
    }
    std::size_t size() const { return fields_.size(); }
};
using json = doc<>;
inline json make_doc() {
    json d;
    d.set("a", 1);
    return d;
}

template <class T>
class box {
    T v_;
public:
    explicit box(T v) : v_(v) {}
    virtual ~box() = default;
    virtual T get() const { return v_; }
};
inline box<int> boxed(int v) { return box<int>(v); }
using ibox = box<int>;

inline auto adder(int k) {
    return [k](int x) { return x + k; };
}

template <class T>
class task {
    T value_;
    bool done_ = false;
public:
    explicit task(T v) : value_(v) {}
    T get() {
        done_ = true;
        return value_;
    }
    bool done() const { return done_; }
};
inline task<int> compute(int x) { return task<int>(x * 2); }

// operators on an instance (by their Volt names), and a function taking one by &&
template <class T>
class num {
    T v_;
public:
    explicit num(T v) : v_(v) {}
    T get() const { return v_; }
    num operator-() const { return num(-v_); }
    num operator+(T d) const { return num(v_ + d); }
    bool operator==(const num &o) const { return v_ == o.v_; }
};
inline num<int> make_num(int v) { return num<int>(v); }
inline std::size_t consume(json &&d) {
    json mine = static_cast<json &&>(d);
    return mine.size();
}
}
