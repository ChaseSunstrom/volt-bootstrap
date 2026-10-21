// there's no @assert: a test block asserts with std::testing
fn main() -> void {
    @assert(1 + 1 == 2);
}
// error: unknown builtin @assert: assertions are std::testing's (use std::testing; then try std::testing::assert(cond) in a test block)
