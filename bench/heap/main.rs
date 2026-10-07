// heap: a binary min-heap used for two element types: n random integers, then n tasks ordered by (priority, id); Rust uses the generic std BinaryHeap with Reverse
use std::cmp::Reverse;
use std::collections::BinaryHeap;

/// ordered by priority, then id
#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct Task {
    priority: u32,
    id: u32,
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(3000000);
    let mut seed: u64 = 88172645463325252;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let mut ints = BinaryHeap::new();
    for _ in 0..n {
        ints.push(Reverse(next() >> 16));
    }
    let (mut sum, mut prev, mut sorted) = (0u64, 0u64, 1u64);
    while let Some(Reverse(v)) = ints.pop() {
        sorted &= (prev <= v) as u64;
        prev = v;
        sum = sum.wrapping_mul(31).wrapping_add(v);
    }
    let mut tasks = BinaryHeap::new();
    for i in 0..n {
        tasks.push(Reverse(Task { priority: (next() % 1000) as u32, id: i as u32 }));
    }
    let mut order = 0u64;
    while let Some(Reverse(t)) = tasks.pop() {
        order = order.wrapping_mul(31).wrapping_add(t.id as u64);
    }
    println!("{sorted} {sum} {order}");
}
