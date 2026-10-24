// members of kinds the C import once skipped (c_member_kinds.h): _Atomic scalars (their layout, read
// and written plainly), _Float16 as f16, unsigned __int128 as u128, and a flexible array member
// through kinds_get_tail and kinds_set_tail (the struct's size C's, which leaves the array out)
use std::io;
use { "c_member_kinds.h" } as c;

fn main() -> void {
    val k = c::kinds_new(3) ?? return;
    k->a = 5;
    k->al = 7000000000;
    k->h = @cast<f16>(2.5);
    k->big = @cast<u128>(3) << 64;
    for (i) in 0..3 {
        c::kinds_set_tail(k, @cast<usize>(i), @cast<i32>(i) * 10);
    }
    std::println("{} {} {} {}", k->a, k->al, @cast<f32>(k->h), @cast<u64>(k->big >> 64));
    std::println("tail {} {}", c::kinds_get_tail(k, 2), k->n);
    std::println("sum {}", c::kinds_sum(k));
    c::free(k);
}
// expect: 5 7000000000 2.5 3
// expect: tail 20 3
// expect: sum 7000000040
