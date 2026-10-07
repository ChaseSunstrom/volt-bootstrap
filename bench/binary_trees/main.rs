// binary-trees (the Benchmarks Game): allocate and walk many perfect binary trees, then free them
struct Node {
    kids: Option<(Box<Node>, Box<Node>)>,
}

fn make(depth: i32) -> Box<Node> {
    Box::new(Node { kids: if depth > 0 { Some((make(depth - 1), make(depth - 1))) } else { None } })
}

fn check(n: &Node) -> i32 {
    1 + n.kids.as_ref().map_or(0, |(l, r)| check(l) + check(r))
}

fn main() {
    let max = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(18).max(6);
    let stretch = make(max + 1);
    println!("stretch tree of depth {}\t check: {}", max + 1, check(&stretch));
    drop(stretch);
    let long_lived = make(max);
    for d in (4..=max).step_by(2) {
        let iters = 1 << (max - d + 4);
        let mut sum = 0;
        for _ in 0..iters {
            sum += check(&make(d));
        }
        println!("{iters}\t trees of depth {d}\t check: {sum}");
    }
    println!("long lived tree of depth {max}\t check: {}", check(&long_lived));
}
