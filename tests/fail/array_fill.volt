// A repeat literal's count is the array's length, and a value that owns something can't be copied
// into every element.

fn short() -> void {
    val a: i32[4] = { 0; 3 };
}

fn not_constant(n: usize) -> void {
    val b: i32[4] = { 0; n };
}

fn owning() -> void {
    val s = std::string::from("x");
    val c: std::string[2] = { s; 2 };
}

fn not_array() -> void {
    val d: i32 = { 1; 1 };
}

fn five() -> i32 {
    return 5;
}

// a global's initializer is worked out at compile time when it's a { } or { x; n } literal or operators
// over constants; a call to a function that isn't comptime is an error
val G: i32 = five();

fn uses_g() -> i32 {
    return G;
}

fn too_big() -> void {
    comptime val big = { 0; 100000000000 };
}

fn wrong_at_compile_time() -> void {
    comptime val c: i32[2] = { 1; 3 };
}

fn main() -> void {}
// error: this repeats 3 times but the array holds 4
// error: a repeat count must be known at compile time
// error: it owns memory; build the elements one by one
// error: a { x; n } literal makes an array, not a i32
// error: global initializers must be constants
// error: a repeat at compile time makes at most 1048576 elements
// error: this repeats 3 times but the array holds 2
