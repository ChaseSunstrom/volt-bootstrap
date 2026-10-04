// A small framework of the kind C++ applications are built on: interfaces with pure virtual
// methods, an event bus calling its listeners, a registry starting its plugins (cpp_framework.volt
// plugs Volt types in)
#pragma once
#include <algorithm>
#include <string>
#include <utility>
#include <vector>

namespace fw {

class Event {
public:
    Event(std::string n, int v) : name(std::move(n)), value(v) {}
    std::string name;
    int value;
};

class Listener {
public:
    virtual ~Listener() = default;
    virtual void on_event(const Event& e) = 0;
    virtual int priority() const { return 0; }
};

class Plugin {
public:
    virtual ~Plugin() = default;
    virtual std::string id() const = 0;
    virtual bool start() { return true; }
    virtual void stop() {}
};

class Bus {
public:
    void subscribe(Listener& l) {
        listeners.push_back(&l);
        std::stable_sort(listeners.begin(), listeners.end(), [](Listener* a, Listener* b) { return a->priority() > b->priority(); });
    }
    int publish(const std::string& name, int v) {
        Event e(name, v);
        for (Listener* l : listeners) l->on_event(e);
        return static_cast<int>(listeners.size());
    }

private:
    std::vector<Listener*> listeners;
};

class Registry {
public:
    void add(Plugin& p) { plugins.push_back(&p); }
    std::string start_all() {
        std::string out;
        for (Plugin* p : plugins) {
            out += p->id();
            out += p->start() ? "+" : "-";
        }
        return out;
    }
    void stop_all() {
        for (Plugin* p : plugins) p->stop();
    }

private:
    std::vector<Plugin*> plugins;
};

}  // namespace fw
