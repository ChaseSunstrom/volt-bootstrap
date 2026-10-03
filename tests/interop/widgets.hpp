// Classes a Volt type subclasses (cpp_derive.volt): virtual methods C++ calls, protected members
#pragma once
#include <string>
#include <utility>
#include <vector>

namespace gui {

struct Size {
    int w, h;
};

enum class Mood { Calm, Busy };

class Widget;
using WidgetRef = const Widget&;  // a reference through a typedef

class Widget {
public:
    explicit Widget(std::string name) : name_(std::move(name)) {}
    virtual ~Widget() = default;

    virtual int width() const = 0;
    virtual std::string describe() const { return name_ + " " + std::to_string(width()); }
    virtual void click(int times) { clicks_ += times; }
    virtual void rename(const std::string& to) { name_ = to; }
    virtual void link(WidgetRef) {}
    virtual Size size() const { return {1, 1}; }
    virtual int react(Mood) { return 0; }
    virtual int id() const noexcept { return 7; }
    // a result Volt can't give: C++'s own, always
    virtual std::vector<int> items() const { return {1, 2}; }

    int clicks() const { return clicks_; }
    std::string title() const { return name_; }
    std::string render() const { return "[" + describe() + "]"; }
    bool shown() const { return visible(); }

protected:
    Widget() : name_("unnamed") {}
    void bump(int n) { clicks_ += n * 100; }
    std::string name_;

private:
    // private and not pure: a Volt type can't override it (C++'s own would be out of reach)
    virtual bool visible() const { return true; }
    int clicks_ = 0;
};

class Button : public Widget {
public:
    explicit Button(std::string name) : Widget(std::move(name)) {}
    int width() const override { return 1; }
    virtual int press() { return clicks() + 1; }
    int ring() const { return sound() * 2; }

private:
    // private and pure: a derived class's to give
    virtual int sound() const = 0;
};

// C++ calling the virtual methods through base references
inline std::string show(const Widget& w) { return w.render(); }
inline int total_width(const Widget& a, const Widget& b) { return a.width() + b.width(); }
inline void link_all(Widget& a, const Widget& b) { a.link(b); }
inline int area_of(const Widget& w) {
    Size s = w.size();
    return s.w * s.h;
}
inline int poke(Widget& w) { return w.react(Mood::Busy); }
inline int press_it(Button& b) { return b.press(); }
inline std::string button_text(const Button& b) { return b.render(); }

}  // namespace gui
