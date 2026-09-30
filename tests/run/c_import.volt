use std::io;
use { "stdio.h", "stdlib.h", "string.h", "time.h" } as c;
use { "c_import.h" } as local;

fn by_value(a: void*, b: void*) -> i32 {
    val x = *@cast<i32&>(a ?? return 0);
    val y = *@cast<i32&>(b ?? return 0);
    return x - y;
}

fn main() -> void {
    c::printf("%d %s\n", 7, "from printf");
    std::println(c::strlen("hello"));
    std::println(c::abs(-5));
    std::println(c::atoi("123") + 1);
    std::println("{} {} {}", local::ANSWER, local::SCALE, local::MASK);
    std::println("{} {} {}", local::RED, local::GREEN, local::BLUE);
    var p: local::point = { x: 3, y: 4 };
    local::point_scale(&p, 10);
    std::println("{} {}", local::point_sum(p), p.x);
    val q: local::pair = { a: 9, b: 2 };
    std::println(local::pair_diff(&q));
    val home = c::getenv("VOLT_SURELY_UNSET_VAR") ?? "none";
    std::println(home);
    var xs: i32[5] = { 5, 1, 4, 2, 3 };
    c::qsort(&xs, 5, @sizeof(i32), by_value);
    std::println(xs);
    c::fputs("to stderr\n", c::stderr);
    val buf = c::malloc(16) ?? return;
    c::memset(buf, 0, 16);
    c::free(buf);
    std::println("{} {}", c::EXIT_FAILURE, c::SEEK_END);
    var t: c::tm = { tm_year: 124 };
    std::println(other::year(&t));
    if (other::out() == c::stdout) {
        std::println("dedup ok");
    }
    var n: local::named = { id: 1 };
    n.name[0] = 111;
    n.name[1] = 107;
    std::println("{} {} {}", local::name_len(&n), n.name[1], n.name.len);
}

// the same header in another namespace shares its types
namespace other {
    use { "time.h", "stdio.h" } as libc;
    fn year(t: c::tm&) -> i32 { return t.tm_year + 1900; }
    fn out() -> c::FILE* { return libc::stdout; }
}
// expect: 7 from printf
// expect: 5
// expect: 5
// expect: 124
// expect: 42 2.5 16
// expect: 0 5 6
// expect: 70 30
// expect: 7
// expect: none
// expect: { 1, 2, 3, 4, 5 }
// expect: 1 2
// expect: 2024
// expect: dedup ok
// expect: 2 107 8
