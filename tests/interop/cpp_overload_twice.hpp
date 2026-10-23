// Overloads Volt can't tell apart whose parameter-type names collide too (cpp_overload_twice.volt):
// each still comes through, under the first free name: the words, then _2, _3
#pragma once
namespace tw {
// f(long) would be f_long, which a real function has: f_long_2
inline int f(long long) { return 1; }
inline int f(long) { return 2; }
inline int f_long(long) { return 3; }
// the real one is in a later block of the namespace: the same
inline int g(long long) { return 1; }
inline int g(long) { return 2; }
}
namespace tw {
inline int g_long(long) { return 3; }
}
namespace tw {
// defaulted parameters: two arities each, whose names must all differ (d_long_long_2 is one arity's name, free there)
inline int d(long long, int = 0) { return 1; }
inline int d(long, int = 0) { return 2; }
inline int d_long_int(long) { return 3; }  // one arity of the name d(long, int = 0) would take
}
namespace tw {
// m(long) const and m(long) are both m_long (and not m, which m(long long) has): the second is m_long_2;
// peek() const has the name, peek() would be peek_nonconst, which a real method has: peek_nonconst_2
struct Twice {
    int m(long long) { return 1; }
    int m(long) const { return 2; }
    int m(long) { return 3; }
    int peek() const { return 4; }
    int peek() { return 5; }
    int peek_nonconst() { return 6; }
};
}
