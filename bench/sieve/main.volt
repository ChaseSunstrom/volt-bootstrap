// sieve: the primes below n with the sieve of Eratosthenes over a byte array
use std::io;
use std::text;

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "200000000").parse_int() catch 200000000);
    var marks: std::vec<u8> = {};
    try marks.reserve(n);
    for (i) in 0..n {
        try marks.push(1);
    }
    val prime = marks.items();
    prime[0] = 0;
    prime[1] = 0;
    var i: usize = 2;
    while (i * i < n) {
        if (prime[i] != 0) {
            var j = i * i;
            while (j < n) {
                prime[j] = 0;
                j += i;
            }
        }
        i += 1;
    }
    var count: usize = 0;
    var last: usize = 0;
    for (k) in 0..n {
        if (prime[k] != 0) {
            count += 1;
            last = k;
        }
    }
    std::println("{} {}", count, last);
}
