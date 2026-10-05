// flags: --test
// a test's name can hold quotes, backslashes and any UTF-8: it's printed as written
use std::testing;

test "says \"hi\" \\ to é" {
    try std::testing::assert(true);
}
// expect: test says "hi" \ to é ... ok
// expect: 1 passed, 0 failed
