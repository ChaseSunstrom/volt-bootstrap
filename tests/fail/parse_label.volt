fn main() -> i32 {
    :outer if (true) {}
    return 0;
}
// error: expected for, while or loop after a label
