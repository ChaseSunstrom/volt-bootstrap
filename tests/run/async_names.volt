use std::io;
// a local named like a param must not share its frame slot
async fn shadow(to: i32, x: i32) -> !i32 {
    errdefer std::println("errdefer ran");
    val to = to * 10;
    suspend;
    if (x < 0) {
        return error;
    }
    return to + x;
}
fn main() -> void {
    std::println(shadow(4, 2) catch 0);
    std::println(shadow(4, -1) catch 0);
}
// expect: 42
// expect: errdefer ran
// expect: 0
