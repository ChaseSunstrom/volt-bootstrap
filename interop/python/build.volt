// python's build file: the C flags for Python.h and libpython, from python3-config ($PYTHON_CONFIG
// to pick another). bolt hands them to every package and program that depends on this one.
use std::io;

// what python3-config prints for these arguments, or null when it can't run
fn ask(argv: str[..]) -> std::string? {
    val r = std::process::capture(argv, "") catch return null;
    if (r.code != 0) {
        return null;
    }
    return std::string::from(r.out.as_str().trim());
}

fn main() -> void {
    val tool = std::process::env("PYTHON_CONFIG") ?? "python3-config";
    val includes: str[2] = { tool, "--includes" };
    val inc = ask(includes[..]);
    if (inc == null) {
        std::eprintln("python: can't run {} --includes: install Python's development files, or set $PYTHON_CONFIG", tool);
        std::process::exit(1);
    }
    // --embed (Python 3.8+) adds -lpythonX.Y, which a program embedding the interpreter needs
    val embed: str[3] = { tool, "--ldflags", "--embed" };
    val plain: str[2] = { tool, "--ldflags" };
    var flags = inc ?? std::string::from("");
    flags.push(' ');
    flags.append((ask(embed[..]) ?? ask(plain[..]) ?? std::string::from("")).as_str());
    for (w) in flags.as_str().words().items() {
        bolt::cc_arg(w);
    }
}
