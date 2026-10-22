// a name std doesn't have but a namespace below it does (std::testing::assert): that path, not the
// closest spelling in std (insert)
fn main() -> void {
    std::assert(true);
}
// error: unknown name 'assert'
// error: did you mean 'std::testing::assert'?
