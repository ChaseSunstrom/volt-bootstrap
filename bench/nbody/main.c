// n-body (the Benchmarks Game): the Jovian planets around the sun, simulated in steps
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { double x, y, z, vx, vy, vz, mass; } body;

static double energy(body *b, int n) {
    double e = 0;
    for (int i = 0; i < n; i++) {
        e += 0.5 * b[i].mass * (b[i].vx * b[i].vx + b[i].vy * b[i].vy + b[i].vz * b[i].vz);
        for (int j = i + 1; j < n; j++) {
            double dx = b[i].x - b[j].x, dy = b[i].y - b[j].y, dz = b[i].z - b[j].z;
            e -= b[i].mass * b[j].mass / sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

static void advance(body *b, int n, double dt) {
    for (int i = 0; i < n; i++) {
        for (int j = i + 1; j < n; j++) {
            double dx = b[i].x - b[j].x, dy = b[i].y - b[j].y, dz = b[i].z - b[j].z;
            double d2 = dx * dx + dy * dy + dz * dz;
            double mag = dt / (d2 * sqrt(d2));
            b[i].vx -= dx * b[j].mass * mag; b[i].vy -= dy * b[j].mass * mag; b[i].vz -= dz * b[j].mass * mag;
            b[j].vx += dx * b[i].mass * mag; b[j].vy += dy * b[i].mass * mag; b[j].vz += dz * b[i].mass * mag;
        }
    }
    for (int i = 0; i < n; i++) {
        b[i].x += dt * b[i].vx; b[i].y += dt * b[i].vy; b[i].z += dt * b[i].vz;
    }
}

int main(int argc, char **argv) {
    int steps = argc > 1 ? atoi(argv[1]) : 20000000;
    const double pi = 3.141592653589793, solar = 4 * pi * pi, days = 365.24;
    body b[5] = {
        {0, 0, 0, 0, 0, 0, solar},
        {4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03 * days, 7.69901118419740425e-03 * days, -6.90460016972063023e-05 * days, 9.54791938424326609e-04 * solar},
        {8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03 * days, 4.99852801234917238e-03 * days, 2.30417297573763929e-05 * days, 2.85885980666130812e-04 * solar},
        {1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03 * days, 2.37847173959480950e-03 * days, -2.96589568540237556e-05 * days, 4.36624404335156298e-05 * solar},
        {1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03 * days, 1.62824170038242295e-03 * days, -9.51592254519715870e-05 * days, 5.15138902046611451e-05 * solar},
    };
    double px = 0, py = 0, pz = 0;
    for (int i = 0; i < 5; i++) { px += b[i].vx * b[i].mass; py += b[i].vy * b[i].mass; pz += b[i].vz * b[i].mass; }
    b[0].vx = -px / solar; b[0].vy = -py / solar; b[0].vz = -pz / solar;
    printf("%.9f\n", energy(b, 5));
    for (int s = 0; s < steps; s++) advance(b, 5, 0.01);
    printf("%.9f\n", energy(b, 5));
    return 0;
}
