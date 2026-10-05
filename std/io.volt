// std::io: println/print (stdout) and eprintln/eprint (stderr); format strings are checked at compile time.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace io {
    // println("a {} b {}", x, y) / println(value) / println()
    @attributes([@intrinsic("println")])
    public fn println() -> void;
    // print("a {} b {}", x, y) / print(value): like println, without the newline
    @attributes([@intrinsic("print")])
    public fn print() -> void;
}

namespace io {
    // the same, to stderr (unbuffered)
    @attributes([@intrinsic("eprintln")])
    public fn eprintln() -> void;
    // like print, to stderr
    @attributes([@intrinsic("eprint")])
    public fn eprint() -> void;
}
