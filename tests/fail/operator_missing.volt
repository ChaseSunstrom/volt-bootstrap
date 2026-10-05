// A struct has only the operators attached to it; the left operand picks them

struct vec2 {
    x: i32;
    y: i32;
}

attach operator +(this: vec2, o: vec2) -> vec2 {
    return { x: this.x + o.x, y: this.y + o.y };
}

fn sub(a: vec2, b: vec2) -> vec2 {
    return a - b;
}

fn negate(a: vec2) -> vec2 {
    return -a;
}

fn element(a: vec2) -> i32 {
    return a[0];
}

fn scaled(a: vec2) -> vec2 {
    return a + 2;
}

fn less(a: vec2, b: vec2) -> bool {
    return a > b;
}

// <= and >= negate <, so it has to give a bool; a <= b is !(b < a), so b's type has to have it
struct score {
    n: i32;
}

attach operator <(this: score, o: i32) -> i32 {
    return this.n - o;
}

fn at_least(s: score) -> bool {
    return s >= 3;
}

fn at_most(s: score) -> bool {
    return s <= 3;
}

fn wrapped(a: vec2, b: vec2) -> vec2 {
    return a +% b;
}

fn main() -> void {}
// error: can't use - on vec2; attach operator - to give it one
// error: can't negate a vec2; attach operator - to give it one
// error: can't index a vec2; attach operator [] to give it one
// error: argument 1 is a i32, but 'operator+' wants a vec2
// error: can't use > on vec2; attach operator < to give it one
// error: >= needs operator < to give a bool, but it gives i32
// error: a <= b calls b's operator <, and i32 has none taking a score
// error: can't use +% on vec2
