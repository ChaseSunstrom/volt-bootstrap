// libvoltvm's build file: LLVM and libclang, found as voltc's own build file finds them (../build.volt)

// llvm-config's answer to one question, or null when that llvm-config isn't there or fails
fn ask(tool: str, what: str) -> std::string? {
    val argv: str[3] = { tool, "--link-shared", what };
    val r = std::process::capture(argv[..], "") catch return null;
    if (r.code != 0) {
        return null;
    }
    return std::string::from(r.out.as_str().trim());
}

// link LLVM and libclang where llvm-config `tool` says they are; false when it doesn't answer
fn use_llvm_config(tool: str) -> bool {
    val inc = ask(tool, "--includedir") ?? return false;
    val lib = ask(tool, "--libdir") ?? return false;
    val libs = ask(tool, "--libs") ?? return false;
    // the default paths need no flags (and -I/usr/include can reorder the system headers)
    if (inc.as_str() != "/usr/include") {
        bolt::cc_arg(std::fmt::format("-I{}", inc.as_str()).as_str());
    }
    if (lib.as_str() != "/usr/lib" && lib.as_str() != "/usr/lib64") {
        bolt::cc_arg(std::fmt::format("-L{}", lib.as_str()).as_str());
        bolt::cc_arg(std::fmt::format("-Wl,-rpath,{}", lib.as_str()).as_str());
    }
    val words = libs.as_str().words();
    for (w) in words.items() {
        bolt::cc_arg(w);
    }
    bolt::link_c("clang");
    return true;
}

// the compiler's LLVM backend (the llvm-c API) and its C and C++ import (libclang). Debian and Ubuntu
// keep them in /usr/lib/llvm-N, off the C compiler's default paths, so llvm-config says where:
// $LLVM_CONFIG, else llvm-config-22 (the version voltc is built for, when several are installed),
// else llvm-config on PATH. Without one, the default paths (Arch, most source installs)
fn link_llvm() -> void {
    val chosen = std::process::env("LLVM_CONFIG");
    if (chosen) {
        if (!use_llvm_config(chosen)) {
            std::io::eprintln("voltc's build: $LLVM_CONFIG ({}) didn't answer --includedir, --libdir and --libs", chosen);
            std::process::exit(1);
        }
        return;
    }
    if (use_llvm_config("llvm-config-22") || use_llvm_config("llvm-config")) {
        return;
    }
    bolt::link_c("LLVM");
    bolt::link_c("clang");
}

fn main() -> void {
    link_llvm();
}
