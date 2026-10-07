// Reference shapes over classes Volt holds by handle (cpp_refs.volt): T*, T&, an uncopyable const T&,
// std::unique_ptr and std::shared_ptr of one, a class holding a vector of unique_ptrs (C++ says it
// copies; it doesn't), and a base reached by two paths
#pragma once
#include <memory>
#include <string>
#include <vector>
namespace rf {
class Widget {
  public:
    explicit Widget(int id) : id_(id), name_("w" + std::to_string(id)) {}
    Widget(const Widget &) = delete;
    int id() const { return id_; }
    void bump() { id_ += 100; }
  private:
    int id_;
    std::string name_;
};
class Shelf {
  public:
    Shelf() { items_.push_back(std::make_unique<Widget>(1)); items_.push_back(std::make_unique<Widget>(2)); }
    Widget *find(int id) { for (auto &w : items_) if (w->id() == id) return w.get(); return nullptr; }
    Widget &first() { return *items_[0]; }
    const Widget &last() const { return *items_.back(); }
    std::unique_ptr<Widget> take() { auto w = std::move(items_.back()); items_.pop_back(); return w; }
    void put(std::unique_ptr<Widget> w) { items_.push_back(std::move(w)); }
    std::shared_ptr<Widget> share(int id) { return std::make_shared<Widget>(id); }
    int count() const { return (int)items_.size(); }
  private:
    std::vector<std::unique_ptr<Widget>> items_;
};
inline int id_of(const Widget *w) { return w ? w->id() : -1; }
inline int shelf_size(std::unique_ptr<Shelf> s) { return s->count(); }
inline void bump(Widget *w) { if (w) w->bump(); }
struct A { int a = 1; virtual ~A() = default; std::string tag = "a"; };
struct B1 : A { int b1 = 2; };
struct B2 : A { int b2 = 3; };
struct D : B1, B2 { int d = 4; };
}
