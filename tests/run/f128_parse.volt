// std::softfloat::parse128: decimal text to the nearest binary128 (ties to even, subnormals, inf),
// checked against Python Fractions (scratch t0477/oracle.py); f128 literals read through it (T-0477)
use std::io;
use std::time;
fn main() -> void {
    std::println("{}", std::softfloat::parse128("0.1"));
    std::println("{}", std::softfloat::parse128("0.2"));
    std::println("{}", std::softfloat::parse128("0.3"));
    std::println("{}", std::softfloat::parse128("3.141592653589793238462643383279502884197"));
    std::println("{}", std::softfloat::parse128("1e4000"));
    std::println("{}", std::softfloat::parse128("6.5e-4966"));
    std::println("{}", std::softfloat::parse128("1.2e4932"));
    std::println("{}", std::softfloat::parse128("1.0"));
    std::println("{}", std::softfloat::parse128("7"));
    std::println("{}", std::softfloat::parse128("1_000.5"));
    std::println("{}", std::softfloat::parse128("0.000000000000000000000000000000000000000000001"));
    std::println("{}", std::softfloat::parse128("1.18973149535723176508575932662800701e4932"));
    std::println("{}", std::softfloat::parse128("3.3621031431120935062626778173217526e-4932"));
    std::println("{}", std::softfloat::parse128("123456789012345678901234567890123456789012345678901234567890"));
    std::println("{}", std::softfloat::parse128("1.00000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125"));
    std::println("{}", std::softfloat::parse128("1.00000000000000000000000000000000028888949165808537795839669138773909778071524723230822928599081933498382568359375"));
    // past 12000 significant digits only whether one isn't 0 matters: a halfway case a 1 far out
    // decides, and 200000 digits read quickly
    var far = std::string::from("1.00000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125");
    for (i) in 0..20000 {
        far.push('0');
    }
    far.push('1');
    std::println("{}", std::softfloat::parse128(far.as_str()));
    var long = std::string::from("1.");
    for (i) in 0..200000 {
        long.push('0');
    }
    val t0 = std::time::now();
    val one = std::softfloat::parse128(long.as_str());
    std::println("{} fast {}", one, t0.elapsed().ns < 500000000);
}
// expect: 85047745624057062624278117674093484442
// expect: 85052937920915597451906648170422704538
// expect: 85056053299030718348483766468220236595
// expect: 85073555474209096226415955104694206904
// expect: 154058763097132682114358074557593881795
// expect: 1
// expect: 170135991163610696904058773219554885632
// expect: 85065399433376081038215121361612832768
// expect: 85079678249737051814193580226518188032
// expect: 85117084083648586407372944944702423040
// expect: 84288773301448510302814124958941154298
// expect: 170135991163610696904058773219554885631
// expect: 5192296858534827628530496329220096
// expect: 86084279887187813800478797289845127363
// expect: 85065399433376081038215121361612832768
// expect: 85065399433376081038215121361612832770
// expect: 85065399433376081038215121361612832769
// expect: 85065399433376081038215121361612832768 fast true
