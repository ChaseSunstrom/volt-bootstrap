// a program that exits 139 itself wasn't ended by a signal: voltc run says nothing about one
fn main() -> i32 {
    std::process::exit(139);
}
// exit: 139
// reject-stderr: ended by
