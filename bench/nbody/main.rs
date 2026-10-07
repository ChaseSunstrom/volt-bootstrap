// n-body (the Benchmarks Game): the Jovian planets around the sun, simulated in steps
#[derive(Clone, Copy)]
struct Body {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    mass: f64,
}

fn energy(b: &[Body]) -> f64 {
    let mut e = 0.0;
    for (i, bi) in b.iter().enumerate() {
        e += 0.5 * bi.mass * (bi.vx * bi.vx + bi.vy * bi.vy + bi.vz * bi.vz);
        for bj in &b[i + 1..] {
            let (dx, dy, dz) = (bi.x - bj.x, bi.y - bj.y, bi.z - bj.z);
            e -= bi.mass * bj.mass / (dx * dx + dy * dy + dz * dz).sqrt();
        }
    }
    e
}

fn advance(b: &mut [Body], dt: f64) {
    for i in 0..b.len() {
        let (left, right) = b.split_at_mut(i + 1);
        let bi = &mut left[i];
        for bj in right {
            let (dx, dy, dz) = (bi.x - bj.x, bi.y - bj.y, bi.z - bj.z);
            let d2 = dx * dx + dy * dy + dz * dz;
            let mag = dt / (d2 * d2.sqrt());
            bi.vx -= dx * bj.mass * mag;
            bi.vy -= dy * bj.mass * mag;
            bi.vz -= dz * bj.mass * mag;
            bj.vx += dx * bi.mass * mag;
            bj.vy += dy * bi.mass * mag;
            bj.vz += dz * bi.mass * mag;
        }
    }
    for bi in b {
        bi.x += dt * bi.vx;
        bi.y += dt * bi.vy;
        bi.z += dt * bi.vz;
    }
}

fn main() {
    let steps: u32 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(20_000_000);
    let pi = 3.141592653589793;
    let solar = 4.0 * pi * pi;
    let days = 365.24;
    let body = |x, y, z, vx: f64, vy: f64, vz: f64, mass: f64| Body { x, y, z, vx: vx * days, vy: vy * days, vz: vz * days, mass: mass * solar };
    let mut b = [
        Body { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: solar },
        body(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05, 9.54791938424326609e-04),
        body(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05, 2.85885980666130812e-04),
        body(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05, 4.36624404335156298e-05),
        body(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05, 5.15138902046611451e-05),
    ];
    let (mut px, mut py, mut pz) = (0.0, 0.0, 0.0);
    for bi in &b {
        px += bi.vx * bi.mass;
        py += bi.vy * bi.mass;
        pz += bi.vz * bi.mass;
    }
    b[0].vx = -px / solar;
    b[0].vy = -py / solar;
    b[0].vz = -pz / solar;
    println!("{:.9}", energy(&b));
    for _ in 0..steps {
        advance(&mut b, 0.01);
    }
    println!("{:.9}", energy(&b));
}
