// for loops over C++ ranges whose iterators Volt can't hold in its own words (one holding a
// std::shared_ptr, a move-only one, an over-aligned one): C++ holds them, and each way out of the
// loop (its end, break, return, try) frees them; and over a std::vector and std::map from a header
// read under C++98
use std::io;
use { "cpp_ranges2.hpp" } as cpp;
@attributes([@standard("c++98")])
use { "cpp_ranges2_98.hpp" } as old;
@attributes([@standard("c++98")])
use cpp { "vector" } as cs98;

error too_big { TOO_BIG }

fn first_over(r: cpp::r2::shared_range&, n: i32) -> i32 {
    for (x) in r {
        if (x > n) {
            return x;
        }
    }
    return -1;
}

fn small(x: i32) -> too_big!i32 {
    if (x > 15) {
        return too_big::TOO_BIG;
    }
    return x;
}

fn sum_small(r: cpp::r2::shared_range&) -> too_big!i32 {
    var s = 0;
    for (x) in r {
        s += try small(x);
    }
    return s;
}

fn main() -> void {
    val sr = cpp::r2::shared_range::new(3);
    var s = 0;
    var inside = 0;
    for (x) in sr {
        s += x;
        inside = *cpp::r2::live();
    }
    std::println("shared {} live {} inside {}", s, *cpp::r2::live(), inside);
    for (x) in sr {
        if (x == 10) {
            break;
        }
    }
    std::println("break live {}", *cpp::r2::live());
    std::println("return {} live {}", first_over(&sr, 5), *cpp::r2::live());
    val t = sum_small(&sr) catch |e| -1;
    std::println("try {} live {}", t, *cpp::r2::live());
    :outer for (a) in sr {
        for (b) in sr {
            if (b == 10) {
                break :outer;
            }
        }
    }
    std::println("labeled break live {}", *cpp::r2::live());
    var odd = 0;
    for (x) in sr {
        if (x == 10) {
            continue;
        }
        odd += x;
    }
    std::println("continue {} live {}", odd, *cpp::r2::live());
    var pairs = 0;
    for (a) in sr {
        for (b) in sr {
            pairs += a + b;
        }
    }
    std::println("nested {} live {}", pairs, *cpp::r2::live());

    val mr = cpp::r2::move_range::new(4);
    var m = 0;
    for (x) in mr {
        m += x;
    }
    for (x) in mr {
        if (x == 2) {
            break;
        }
    }
    std::println("move {} live {}", m, *cpp::r2::live());

    val wr = cpp::r2::wide_range::new(4);
    var w = 0;
    for (x) in wr {
        w += x;
    }
    std::println("wide {}", w);

    var ov: cs98::stdcxx::vector<i32> = {};
    val one: i32 = 1;
    ov.push_back(one);
    ov.push_back(one + 1);
    ov.push_back(one + 2);
    val om = old::r98::table();
    var o = 0;
    for (x) in ov {
        o += x;
    }
    // (a std::pair is a handle under C++98: no std::tuple_size to read it as a tuple by)
    var entries = 0;
    for (kv) in om {
        entries += 1;
    }
    std::println("c++98 {} {}", o, entries);
}
