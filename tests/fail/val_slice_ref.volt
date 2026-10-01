// std's slice methods take this: T[..]&, and sorting writes the elements: not a val array's
fn main() -> void {
    val nums: i32[3] = { 3, 1, 2 };
    nums[..].sort();
}
// error: 'nums' is a val, and sort changes it (through this): declare it with var
