// classes Volt used to leave out: an over-aligned one, a class template with a field of no Volt
// form, a class whose destructor isn't public
#pragma once
#include <mutex>

namespace lo {
// aligned past what Volt's words show: held by handle, made and freed by C++'s aligned new/delete
struct alignas(32) vec8 {
    float v[8];
    int tag;
    void fill(float x) {
        for (int i = 0; i < 8; i++) {
            v[i] = x + (float)i;
        }
    }
    float sum() const {
        float s = 0;
        for (int i = 0; i < 8; i++) {
            s += v[i];
        }
        return s;
    }
    bool aligned() const { return ((unsigned long)this % 32) == 0; }
};

// a field Volt has no form for (std::mutex): a generic handle
template <class T>
struct guarded {
    T v;
    std::mutex m;
    T get() {
        std::lock_guard<std::mutex> g(m);
        return v;
    }
    void set(T x) {
        std::lock_guard<std::mutex> g(m);
        v = x;
    }
};

// freed by its own destroy, never by Volt (its destructor is protected)
static int sessions_deleted = 0;
class session {
protected:
    ~session() { sessions_deleted++; }
public:
    int id;
    static session *create(int id) {
        session *s = new session();
        s->id = id;
        return s;
    }
    static void destroy(session *s) { delete s; }
    int twice() const { return id * 2; }
};
inline int deleted() { return sessions_deleted; }
}
