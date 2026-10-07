// dijkstra: shortest paths over an n x n grid whose edges have random weights, from two corners, with a binary heap of (distance, node) and lazy deletion
use std::cmp::Reverse;
use std::collections::BinaryHeap;

/// distances from src to every node; weight[node * 4 + d] is the cost of leaving node in direction d
fn shortest(n: usize, weight: &[u32], src: u32, dist: &mut [u64], relaxed: &mut u64) {
    dist.fill(u64::MAX);
    let mut heap = BinaryHeap::with_capacity(1024);
    dist[src as usize] = 0;
    heap.push(Reverse((0u64, src)));
    while let Some(Reverse((cd, node))) = heap.pop() {
        if cd > dist[node as usize] {
            continue;
        }
        let (x, y) = (node as usize % n, node as usize / n);
        for d in 0..4 {
            let (nx, ny) = match d {
                0 if x + 1 < n => (x + 1, y),
                1 if x > 0 => (x - 1, y),
                2 if y + 1 < n => (x, y + 1),
                3 if y > 0 => (x, y - 1),
                _ => continue,
            };
            let to = ny * n + nx;
            let nd = cd + weight[node as usize * 4 + d] as u64;
            if nd < dist[to] {
                dist[to] = nd;
                *relaxed += 1;
                heap.push(Reverse((nd, to as u32)));
            }
        }
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1500);
    let count = n * n;
    let mut seed: u64 = 88172645463325252;
    let weight: Vec<u32> = (0..count * 4)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed % 100) as u32 + 1
        })
        .collect();
    let mut dist = vec![0u64; count];
    let mut relaxed = 0u64;
    let sources = [0u32, (count - 1) as u32];
    for s in 0..2 {
        shortest(n, &weight, sources[s], &mut dist, &mut relaxed);
        let sum: u64 = dist.iter().sum();
        let far = dist.iter().copied().max().unwrap_or(0);
        println!("from {}: corner {}, farthest {far}, sum {sum}", sources[s], dist[sources[1 - s] as usize]);
    }
    println!("relaxed {relaxed}");
}
