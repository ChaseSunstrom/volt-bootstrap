val SEED: i32 = 3;
@attributes([@section(".data.table")])
val TABLE: i32[2] = { SEED, 4 };
fn main() -> i32 { return TABLE[0]; }
// error: 'TABLE' is in a section
// error: has to be constants
