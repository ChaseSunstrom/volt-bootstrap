// a C header may name a struct and a function alike (struct stat, stat()); both import
use std::io;
use { "sys/stat.h" } as st;

fn main() -> i32 {
    var info: st::stat = {};
    val r = st::stat("/", &info);
    std::println("{} {}", r, (info.st_mode & 0o170000) == 0o040000);
    return 0;
}
// expect: 0 true
