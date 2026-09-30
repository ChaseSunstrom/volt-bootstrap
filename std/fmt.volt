// std::fmt: formatting into anything. write(&out, "a {} b {:>5}", x, y) appends to any value whose
// type attaches write_str(this: T&, s: str) -> void; format(...) returns the text as a new string.
// Format strings are checked at compile time, like println's; {:spec} works in all of them.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace fmt {
    // write(&out, "a {} b {}", x, y): the formatted text, handed to out's write_str
    @attributes([@intrinsic("write")])
    fn write() -> void;
    // format("a {} b {}", x, y): the formatted text as a new string
    @attributes([@intrinsic("format")])
    fn format() -> std::string;
}
