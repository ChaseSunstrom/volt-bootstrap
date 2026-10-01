// dotnet's build file: libhostfxr from the .NET install that `dotnet --list-runtimes` reports
// ($DOTNET_ROOT/dotnet when it's set, else the dotnet on PATH), linked with an rpath to it. hostfxr
// finds the runtime next to itself.
use std::io;

fn main() -> void {
    var dotnet = std::string::from("dotnet");
    val root_env = std::process::env("DOTNET_ROOT");
    if (root_env) {
        dotnet = std::fmt::format("{}/dotnet", root_env);
    }
    val argv: str[2] = { dotnet.as_str(), "--list-runtimes" };
    val r = std::process::capture(argv[..], "") catch |e| {
        std::eprintln("dotnet: can't run {}: install .NET, or set $DOTNET_ROOT", dotnet.as_str());
        std::process::exit(1);
    };
    // the newest runtime: "Microsoft.NETCore.App 10.0.12 [/opt/dotnet/shared/Microsoft.NETCore.App]"
    var version = std::string::from("");
    var root = std::string::from("");
    for (line) in r.out.as_str().lines().items() {
        val l = line.trim();
        val tail = " [";
        if (l.starts_with("Microsoft.NETCore.App ") && l.ends_with("/shared/Microsoft.NETCore.App]")) {
            val at = l.find(tail) ?? continue;
            version = std::string::from(l[22..at]);
            root = std::string::from(l[at + 2..l.len - 30]);
        }
    }
    if (root.len() == 0) {
        std::eprintln("dotnet: {} --list-runtimes lists no Microsoft.NETCore.App runtime", dotnet.as_str());
        std::process::exit(1);
    }
    // host/fxr/<version>, else the one hostfxr that's there
    var fxr = std::fmt::format("{}/host/fxr/{}", root.as_str(), version.as_str());
    if (!std::fs::is_dir(fxr.as_str())) {
        val base = std::fmt::format("{}/host/fxr", root.as_str());
        val names = std::fs::list_dir(base.as_str()) catch |e| {
            std::eprintln("dotnet: no hostfxr under {}", base.as_str());
            std::process::exit(1);
        };
        if (names.len == 0) {
            std::eprintln("dotnet: no hostfxr under {}", base.as_str());
            std::process::exit(1);
        }
        fxr = std::fmt::format("{}/{}", base.as_str(), names.items()[names.len - 1].as_str());
    }
    bolt::cc_arg(std::fmt::format("-L{}", fxr.as_str()).as_str());
    bolt::cc_arg(std::fmt::format("-Wl,-rpath,{}", fxr.as_str()).as_str());
    bolt::link_c("hostfxr");
}
