// a std::map with no stdcxx form (a std::string key) that C++ makes, passed back to a function taking
// it by const& (its handle: the object itself), and a Volt std::map passed to the same function (a
// copy); C++98-compatible, so it reads under C++11 as under C++17 (cpp_map_back.volt)
#include <map>
#include <string>
#include <vector>

namespace mb {
inline std::map<std::string, int> make() { std::map<std::string, int> m; m["a"] = 1; m["b"] = 2; return m; }
// a std::vector of such maps, or of another class held by handle, has no Volt slice form (a slice of
// handles isn't the objects): per use, and the import still compiles
struct named { std::string s; };
inline std::vector<std::map<std::string, int> > maps() { return std::vector<std::map<std::string, int> >(2); }
inline int count(const std::vector<std::map<std::string, int> > &v) { return (int)v.size(); }
inline std::vector<named> names() { return std::vector<named>(3); }
inline int total(const std::map<std::string, int> &m) {
    int t = 0;
    for (std::map<std::string, int>::const_iterator i = m.begin(); i != m.end(); ++i) t += i->second;
    return t;
}
}
