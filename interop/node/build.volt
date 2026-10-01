// node's build file: where Node-API's headers are (node_api.h), from the node on PATH, else the
// usual system places. An addon is a shared library whose napi_* symbols node itself provides, so
// nothing is linked; macOS needs to be told that.
use std::io;

// the include directory next to the node on PATH, or null
fn node_include() -> std::string? {
    val argv: str[3] = { "node", "-p", "require('path').join(process.execPath, '..', '..', 'include', 'node')" };
    val r = std::process::capture(argv[..], "") catch return null;
    return std::string::from(r.out.as_str().trim());
}

fn main() -> void {
    var dirs: std::vec<std::string> = {};
    dirs.push(node_include() ?? std::string::from("")) catch return;
    dirs.push(std::string::from("/usr/include/node")) catch return;
    dirs.push(std::string::from("/usr/local/include/node")) catch return;
    for (d&) in dirs.items() {
        val probe = std::fmt::format("{}/node_api.h", d.as_str());
        if (std::fs::exists(probe.as_str())) {
            bolt::cc_arg(std::fmt::format("-I{}", d.as_str()).as_str());
            if (@cfg("os", "macos")) {
                bolt::cc_arg("-Wl,-undefined,dynamic_lookup");
            }
            return;
        }
    }
    std::eprintln("node: can't find node_api.h (Node's headers): install Node.js with its headers");
    std::process::exit(1);
}
