// a builtin's argument that could be a type or a value (body[0]: an array type, or indexing)
// is read as the value when the builtin wants one
use std::io;

fn main() -> i32 {
    val body: u8[3] = { 1, 2, 200 };
    val grid: i32[2][2] = { { 1, 2 }, { 3, 4 } };
    std::println("{} {} {}", @cast<u32>(body[2]), @cast<i64>(grid[1][0]), @sizeof(u8[3]));
    return 0;
}
// expect: 200 3 3
