#pragma once
// an auto result: each call is made per use, its explicit template arguments spelled for C++
template <class T> auto size_of() { return sizeof(T); }
