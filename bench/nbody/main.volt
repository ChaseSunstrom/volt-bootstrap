// n-body (the Benchmarks Game): the Jovian planets around the sun, simulated in steps
use std::io;
use std::math;
use std::text;

struct body {
    x: f64;
    y: f64;
    z: f64;
    vx: f64;
    vy: f64;
    vz: f64;
    mass: f64;
}

fn energy(b: body[..]) -> f64 {
    var e = 0.0;
    for (i) in 0..b.len {
        e += 0.5 * b[i].mass * (b[i].vx * b[i].vx + b[i].vy * b[i].vy + b[i].vz * b[i].vz);
        for (j) in i + 1..b.len {
            val dx = b[i].x - b[j].x;
            val dy = b[i].y - b[j].y;
            val dz = b[i].z - b[j].z;
            e -= b[i].mass * b[j].mass / std::math::sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

fn advance(b: body[..], dt: f64) -> void {
    for (i) in 0..b.len {
        for (j) in i + 1..b.len {
            val dx = b[i].x - b[j].x;
            val dy = b[i].y - b[j].y;
            val dz = b[i].z - b[j].z;
            val d2 = dx * dx + dy * dy + dz * dz;
            val mag = dt / (d2 * std::math::sqrt(d2));
            b[i].vx -= dx * b[j].mass * mag;
            b[i].vy -= dy * b[j].mass * mag;
            b[i].vz -= dz * b[j].mass * mag;
            b[j].vx += dx * b[i].mass * mag;
            b[j].vy += dy * b[i].mass * mag;
            b[j].vz += dz * b[i].mass * mag;
        }
    }
    for (i) in 0..b.len {
        b[i].x += dt * b[i].vx;
        b[i].y += dt * b[i].vy;
        b[i].z += dt * b[i].vz;
    }
}

fn main() -> void {
    val steps = (std::process::arg(1) ?? "20000000").parse_int() catch 20000000;
    val pi = 3.141592653589793;
    val solar = 4.0 * pi * pi;
    val days = 365.24;
    var b: body[] = {
        { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: solar },
        { x: 4.84143144246472090e+00, y: -1.16032004402742839e+00, z: -1.03622044471123109e-01, vx: 1.66007664274403694e-03 * days, vy: 7.69901118419740425e-03 * days, vz: -6.90460016972063023e-05 * days, mass: 9.54791938424326609e-04 * solar },
        { x: 8.34336671824457987e+00, y: 4.12479856412430479e+00, z: -4.03523417114321381e-01, vx: -2.76742510726862411e-03 * days, vy: 4.99852801234917238e-03 * days, vz: 2.30417297573763929e-05 * days, mass: 2.85885980666130812e-04 * solar },
        { x: 1.28943695621391310e+01, y: -1.51111514016986312e+01, z: -2.23307578892655734e-01, vx: 2.96460137564761618e-03 * days, vy: 2.37847173959480950e-03 * days, vz: -2.96589568540237556e-05 * days, mass: 4.36624404335156298e-05 * solar },
        { x: 1.53796971148509165e+01, y: -2.59193146099879641e+01, z: 1.79258772950371181e-01, vx: 2.68067772490389322e-03 * days, vy: 1.62824170038242295e-03 * days, vz: -9.51592254519715870e-05 * days, mass: 5.15138902046611451e-05 * solar },
    };
    var px = 0.0;
    var py = 0.0;
    var pz = 0.0;
    for (p) in b {
        px += p.vx * p.mass;
        py += p.vy * p.mass;
        pz += p.vz * p.mass;
    }
    b[0].vx = -px / solar;
    b[0].vy = -py / solar;
    b[0].vz = -pz / solar;
    std::println("{:.9}", energy(b[..]));
    for (s) in 0..steps {
        advance(b[..], 0.01);
    }
    std::println("{:.9}", energy(b[..]));
}
