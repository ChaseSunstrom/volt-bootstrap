// package geo: every file here is wrapped in namespace geo
public struct rect { w: i32; h: i32; }

public fn area(r: rect) -> i32 {
    return scale(r.w * r.h); // util.volt, same package
}
