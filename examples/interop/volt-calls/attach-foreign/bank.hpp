// C++ classes Volt didn't declare: one Volt lays out (plain fields), one it holds by handle
#pragma once
#include <string>
namespace bank {
struct money {
    long cents;
};
class account {
    std::string owner_;
    long cents_ = 0;
public:
    explicit account(std::string owner) : owner_(std::move(owner)) {}
    void deposit(long c) { cents_ += c; }
    long balance() const { return cents_; }
    std::string owner() const { return owner_; }
};
}
