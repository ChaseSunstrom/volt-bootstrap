// java's build file: JNI's headers and libjvm from the JDK at $JAVA_HOME, else the one whose java
// is on PATH (its java.home). The program finds libjvm through an rpath to it.
use std::io;

// the JDK's directory: $JAVA_HOME, or java.home as `java -XshowSettings:properties` reports it
fn jdk() -> std::string? {
    val home = std::process::env("JAVA_HOME");
    if (home) {
        return std::string::from(home);
    }
    val argv: str[3] = { "java", "-XshowSettings:properties", "-version" };
    val r = std::process::capture(argv[..], "") catch return null;
    for (line) in r.err.as_str().lines().items() {
        val l = line.trim();
        if (l.starts_with("java.home = ")) {
            return std::string::from(l[12..l.len]);
        }
    }
    return null;
}

fn main() -> void {
    val home = jdk();
    if (home == null) {
        std::eprintln("java: can't find a JDK: set $JAVA_HOME, or put its java on PATH");
        std::process::exit(1);
    }
    val h = home ?? std::string::from("");
    var os = "linux";
    if (@cfg("os", "macos")) {
        os = "darwin";
    }
    bolt::cc_arg(std::fmt::format("-I{}/include", h.as_str()).as_str());
    bolt::cc_arg(std::fmt::format("-I{}/include/{}", h.as_str(), os).as_str());
    bolt::cc_arg(std::fmt::format("-L{}/lib/server", h.as_str()).as_str());
    bolt::cc_arg(std::fmt::format("-Wl,-rpath,{}/lib/server", h.as_str()).as_str());
    bolt::link_c("jvm");
}
