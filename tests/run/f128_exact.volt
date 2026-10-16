// f128 constants are binary128-exact: a literal is read to binary128, and compile-time folds of f128
// constants are done in binary128 (T-0477). The expected bits come from Python's Fractions (exact
// rationals, rounded to nearest, ties to even), independent of the compiler: scratch t0477/oracle.py
use std::io;

val G: f128 = 0.1;
val THIRD: f128 = 1.0 / 3.0;
val SEVENTH: f128 = @cast<f128>(1) / 7.0;
val ONE: f128 = @cast<f128>(1);
val H: f128 = G * 2.0;
val SUM: f128 = 0.1 + 0.2;
val A: f64 = 0.1;
val WIDE: f128 = A; // an f64's value widened, not the literal
val UNTYPED = 0.1 * G; // the untyped 0.1 read as binary128 beside an f128
val BIG: f128 = 12345678901234567890123; // past a double's 53 bits

fn b(x: f128) -> u128 {
    return @bitcast<u128>(x);
}

fn main() -> void {
    val local: f128 = 0.2;
    std::println("{}", b(G));
    std::println("{}", b(local));
    std::println("{}", b(0.3));
    std::println("{}", b(3.141592653589793238462643383279502884197));
    std::println("{}", b(1e4000));
    std::println("{}", b(6.5e-4966));
    std::println("{}", b(1.2e4932));
    std::println("{}", b(1.00000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125));
    std::println("{}", b(1.00000000000000000000000000000000028888949165808537795839669138773909778071524723230822928599081933498382568359375));
    std::println("{}", b(THIRD));
    std::println("{}", b(SEVENTH));
    std::println("{}", b(ONE));
    std::println("{}", b(H));
    std::println("{}", b(SUM));
    var one: f128 = 1.0;
    std::println("{} {}", b(one / 3.0) == b(THIRD), b(one / 7.0) == b(SEVENTH));
    std::println("{}", b(WIDE));
    std::println("{}", b(UNTYPED));
    std::println("{}", b(-0.1));
    std::println("{}", b(BIG));
    std::println("{}", b(0.1 * one));
}
// expect: 85047745624057062624278117674093484442
// expect: 85052937920915597451906648170422704538
// expect: 85056053299030718348483766468220236595
// expect: 85073555474209096226415955104694206904
// expect: 154058763097132682114358074557593881795
// expect: 1
// expect: 170135991163610696904058773219554885632
// expect: 85065399433376081038215121361612832768
// expect: 85065399433376081038215121361612832770
// expect: 85056745605278522992167570534397465941
// expect: 85050564299494552959276462800672203922
// expect: 85065399433376081038215121361612832768
// expect: 85052937920915597451906648170422704538
// expect: 85056053299030718348483766468220236596
// expect: true true
// expect: 85047745624057062624739286275936223232
// expect: 85030507198486726996551396426280473724
// expect: 255188929084526294355965421389977590170
// expect: 85446031915942936746907751658138107904
// expect: 85047745624057062624278117674093484442
