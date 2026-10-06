// spectral-norm (the Benchmarks Game): the largest eigenvalue of an infinite matrix, by power iteration
use std::io;
use std::math;
use std::text;

fn a(i: i32, j: i32) -> f64 {
    return 1.0 / @cast<f64>((i + j) * (i + j + 1) / 2 + i + 1);
}

fn times(v: f64[..], out: f64[..]) -> void {
    for (i) in 0..v.len {
        var s = 0.0;
        for (j) in 0..v.len {
            s += a(@cast<i32>(i), @cast<i32>(j)) * v[j];
        }
        out[i] = s;
    }
}

fn times_t(v: f64[..], out: f64[..]) -> void {
    for (i) in 0..v.len {
        var s = 0.0;
        for (j) in 0..v.len {
            s += a(@cast<i32>(j), @cast<i32>(i)) * v[j];
        }
        out[i] = s;
    }
}

fn ata(v: f64[..], out: f64[..], tmp: f64[..]) -> void {
    times(v, tmp);
    times_t(tmp, out);
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "5500").parse_int() catch 5500);
    var u: std::vec<f64> = {};
    var v: std::vec<f64> = {};
    var tmp: std::vec<f64> = {};
    for (i) in 0..n {
        try u.push(1.0);
        try v.push(0.0);
        try tmp.push(0.0);
    }
    for (k) in 0..10 {
        ata(u.items(), v.items(), tmp.items());
        ata(v.items(), u.items(), tmp.items());
    }
    var vbv = 0.0;
    var vv = 0.0;
    for (i) in 0..n {
        vbv += *u.at(i) * *v.at(i);
        vv += *v.at(i) * *v.at(i);
    }
    std::println("{:.9}", std::math::sqrt(vbv / vv));
}
