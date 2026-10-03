use std::io;
// std::path's Windows rules, run on Linux: built with --cfg os=windows, linked with the Windows
// functions std names but this never calls left unresolved (tests/selfhost.rs, windows_paths_run)

fn main() -> void {
    std::println("[{}] [{}] [{}] [{}] [{}]", std::path::parent("C:\\a\\b"), std::path::parent("C:\\a"), std::path::parent("C:\\"), std::path::parent("a/b\\c"), std::path::parent("\\\\server\\share"));
    std::println("[{}] [{}] [{}] [{}]", std::path::file_name("C:\\a\\b.txt"), std::path::file_name("C:\\"), std::path::file_name("a\\b\\"), std::path::extension("C:\\a.b\\c") ?? "none");
    std::println("{} {} {} {} {}", std::path::is_absolute("C:\\x"), std::path::is_absolute("D:/x"), std::path::is_absolute("\\x"), std::path::is_absolute("C:x"), std::path::is_absolute("x\\y"));
    val (j1, j2, j3) = (std::path::join("C:\\d", "x"), std::path::join("C:\\d\\", "x"), std::path::join("a", "C:\\y"));
    std::println("[{}] [{}] [{}]", j1.as_str(), j2.as_str(), j3.as_str());
    val (n1, n2, n3, n4) = (std::path::normalize("C:\\a\\.\\b\\..\\c\\"), std::path::normalize("C:/../x"), std::path::normalize("\\\\server\\share\\..\\y"), std::path::normalize("a/b\\..\\c"));
    std::println("[{}] [{}] [{}] [{}]", n1.as_str(), n2.as_str(), n3.as_str(), n4.as_str());
}
// expect: [C:\a] [C:\] [C:\] [a/b] [\\server]
// expect: [b.txt] [] [b] [none]
// expect: true true true false false
// expect: [C:\d\x] [C:\d\x] [C:\y]
// expect: [C:\a\c] [C:/x] [\\server\y] [a\c]
