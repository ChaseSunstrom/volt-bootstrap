// a right-hand operator serves k * d only: d * k needs d's own (this first)
struct dir {
    dx: i32;
    dy: i32;
}

attach operator *(k: i32, this: dir) -> dir {
    return { dx: k * this.dx, dy: k * this.dy };
}

fn twice(d: dir) -> dir {
    return d * 2;
}

fn main() -> void {}
// error: can't use * on dir; attach operator * to give it one
