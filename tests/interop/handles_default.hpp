// handle classes (not trivially copyable): one with a default constructor, one without
#pragma once
#include <string>
namespace h {
class named { std::string n_; public: named() : n_("anon") {} explicit named(std::string n) : n_(std::move(n)) {} std::string name() const { return n_; } };
class only { std::string n_; public: explicit only(std::string n) : n_(std::move(n)) {} std::string name() const { return n_; } };
}
