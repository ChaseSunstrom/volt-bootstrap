// std::simd: vectors of numbers kept in SIMD registers, so one operation works on every lane at once.
// vec(T, n) is the vector of n Ts (ints of up to 64 bits or f32/f64; n a power of two, 64 bytes at
// most); the usual ones have names. Two vectors of one type add, subtract and multiply lane by lane
// (int lanes wrap, as SIMD does), float lanes divide too and int lanes take & | ^, - negates every
// lane, v[i] reads or writes lane i (checked, as an array's index is), and a { } literal lists the
// lanes ({} is every lane 0).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace simd {
    // the vector of n lanes of T
    public comptime fn vec(T: type, n: usize) -> type {
        return @vector(T, n);
    }

    public type f32x4 = vec(f32, 4);
    public type f32x8 = vec(f32, 8);
    public type f64x2 = vec(f64, 2);
    public type f64x4 = vec(f64, 4);
    public type i32x4 = vec(i32, 4);
    public type i32x8 = vec(i32, 8);
    public type i64x2 = vec(i64, 2);
    public type u8x16 = vec(u8, 16);

    // what each of V's lanes holds
    public comptime fn lane(V: type) -> type {
        comptime match (@typeinfo(V).kind) {
            .VECTOR(v) => { return v.0; },
            default => { @compile_error("std::simd: " + @typeinfo(V).short_name + " isn't a vector"); },
        }
    }

    // how many lanes V has
    public comptime fn lanes(V: type) -> usize {
        comptime match (@typeinfo(V).kind) {
            .VECTOR(v) => { return v.1; },
            default => { @compile_error("std::simd: " + @typeinfo(V).short_name + " isn't a vector"); },
        }
    }

    // the vector with x in every lane: splat<std::simd::f64x4>(1.0)
    <V: type>
    public fn splat(x: lane(V)) -> V {
        var v: V = {};
        comptime for (i) in 0..lanes(V) {
            v[i] = x;
        }
        return v;
    }

    // v's lanes added up
    <V: type>
    public fn sum(v: V) -> lane(V) {
        var s = v[0];
        comptime for (i) in 1..lanes(V) {
            s += v[i];
        }
        return s;
    }

    // the vector of xs' first lanes: load<std::simd::f64x4>(xs[i..]) (xs has at least that many)
    <V: type>
    public fn load(xs: lane(V)[..]) -> V {
        val s = xs[0..lanes(V)];
        var v: V = {};
        comptime for (i) in 0..lanes(V) {
            v[i] = s[i];
        }
        return v;
    }

    // v's lanes into xs' first elements (xs has at least as many)
    <V: type>
    public fn store(v: V, xs: lane(V)[..]) -> void {
        val s = xs[0..lanes(V)];
        comptime for (i) in 0..lanes(V) {
            s[i] = v[i];
        }
    }
}
