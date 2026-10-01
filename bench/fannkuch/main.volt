// fannkuch-redux (the Benchmarks Game): pancake flips over every permutation of 1..n
use std::io;
use std::text;

fn main() -> void {
    val n = @cast<usize>((std::process::arg(1) ?? "11").parse_int() catch 11);
    var perm: i32[16];
    var perm1: i32[16];
    var count: i32[16];
    var max_flips = 0;
    var checksum = 0;
    var perm_count = 0;
    var r = n;
    for (i) in 0..n {
        perm1[i] = @cast<i32>(i);
    }
    loop {
        while (r != 1) {
            count[r - 1] = @cast<i32>(r);
            r -= 1;
        }
        for (i) in 0..n {
            perm[i] = perm1[i];
        }
        var flips = 0;
        var k = perm[0];
        while (k != 0) {
            var i: usize = 0;
            var j = @cast<usize>(k);
            while (i < j) {
                val t = perm[i];
                perm[i] = perm[j];
                perm[j] = t;
                i += 1;
                j -= 1;
            }
            flips += 1;
            k = perm[0];
        }
        if (flips > max_flips) {
            max_flips = flips;
        }
        if (perm_count % 2 == 0) {
            checksum += flips;
        } else {
            checksum -= flips;
        }
        loop {
            if (r == n) {
                std::println("{}\nPfannkuchen({}) = {}", checksum, n, max_flips);
                return;
            }
            val p0 = perm1[0];
            for (i) in 0..r {
                perm1[i] = perm1[i + 1];
            }
            perm1[r] = p0;
            count[r] -= 1;
            if (count[r] > 0) {
                break;
            }
            r += 1;
        }
        perm_count += 1;
    }
}
