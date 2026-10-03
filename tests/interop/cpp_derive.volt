// Volt types subclassing C++ classes: each attaches the t_<Class>_<method> traits of the virtual
// methods it overrides, and <Class>::derive makes the C++ object, which holds the Volt value
use std::io;
use { "widgets.hpp" } as cpp;

struct boxy {
    w: i32;
    log: std::string;
}

attach fn delete(this: boxy&) -> void {
    std::println("boxy {} gone", this.w);
}

attach cpp::gui::t_Widget_width -> boxy {
    fn width(this, self: cpp::gui::Widget&) -> i32 { return this.w; }
}

attach cpp::gui::t_Widget_click -> boxy {
    fn click(this, self: cpp::gui::Widget&, times: i32) -> void {
        this.w += times;
        self.bump(times);       // protected
        self.base_click(times); // C++'s own click
    }
}

attach cpp::gui::t_Widget_describe -> boxy {
    fn describe(this, self: cpp::gui::Widget&) -> std::string {
        var s = self.base_describe();
        s.append(" boxy");
        return move s;
    }
}

attach cpp::gui::t_Widget_rename -> boxy {
    fn rename(this, self: cpp::gui::Widget&, to: str) -> void {
        this.log.append(to);
        self.set_name_(to); // a protected field
    }
}

attach cpp::gui::t_Widget_link -> boxy {
    fn link(this, self: cpp::gui::Widget&, other: cpp::gui::Widget&) -> void {
        this.log.append(other.title().as_str());
    }
}

attach cpp::gui::t_Widget_size -> boxy {
    fn size(this, self: cpp::gui::Widget&) -> cpp::gui::Size { return { w: this.w, h: 2 }; }
}

attach cpp::gui::t_Widget_react -> boxy {
    fn react(this, self: cpp::gui::Widget&, m: cpp::gui::Mood) -> i32 { return @cast<i32>(m) + 40; }
}

struct label {
    text: str;
}

attach cpp::gui::t_Widget_width -> label {
    fn width(this, self: cpp::gui::Widget&) -> i32 { return @cast<i32>(this.text.len); }
}

struct knob {
    n: i32;
}

attach cpp::gui::t_Button_press -> knob {
    fn press(this, self: cpp::gui::Button&) -> i32 { return this.n + self.base_press(); }
}

attach cpp::gui::t_Button_sound -> knob {
    fn sound(this, self: cpp::gui::Button&) -> i32 { return this.n * 3; }
}

attach cpp::gui::t_Button_describe -> knob {
    fn describe(this, self: cpp::gui::Button&) -> std::string { return std::string::from("knob"); }
}

fn main() -> void {
    val b: boxy = { w: 3, log: std::string::from("log:") };
    var w = cpp::gui::Widget::derive(move b, "ok");
    w.click(2);
    std::println("{} clicks {} shown {}", cpp::gui::show(&w), w.clicks(), w.shown());
    val l: label = { text: "hello" };
    val lw = cpp::gui::Widget::derive(move l, "lbl");
    std::println("{} {} {}", cpp::gui::show(&lw), cpp::gui::total_width(&w, &lw), lw.shown());
    w.rename("x");
    cpp::gui::link_all(&w, &lw);
    std::println("{} area {} poke {} id {}", cpp::gui::show(&w), cpp::gui::area_of(&w), cpp::gui::poke(&w), w.id());
    val mine = w.derived<boxy>() ?? @panic("not a boxy");
    std::println("mine {} {} {}", mine.w, mine.log, lw.derived<boxy>() == null);
    val k: knob = { n: 10 };
    var kb = cpp::gui::Button::derive(move k, "k");
    std::println("press {} {} ring {}", cpp::gui::press_it(&kb), cpp::gui::button_text(&kb), kb.ring());
}
