use std::io;
// std::process::windows_args: arguments quoted as the Windows C runtime reads them back

fn show(argv: str[..]) -> void {
    val line = std::process::windows_args(argv);
    std::println("[{}]", line.as_str());
}

fn main() -> void {
    val a: str[4] = { "prog", "a", "b c", "" };
    val b: str[2] = { "C:\\Program Files\\x.exe", "a\\b" };
    val c: str[1] = { "say \"hi\"" };
    val d: str[2] = { "ends in\\", "q\\\"x" };
    val e: str[2] = { "tab\there", "no-quotes-needed" };
    show(a[..]);
    show(b[..]);
    show(c[..]);
    show(d[..]);
    show(e[..]);
}
// expect: [prog a "b c" ""]
// expect: ["C:\Program Files\x.exe" a\b]
// expect: ["say \"hi\""]
// expect: ["ends in\\" "q\\\"x"]
// expect: ["tab	here" no-quotes-needed]
