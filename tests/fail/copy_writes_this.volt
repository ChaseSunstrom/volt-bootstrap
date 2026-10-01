// copying a val calls its copy fn on it, so copy can only read this
struct counted {
    copies: i32 = 0;
}

attach fn delete(this: counted&) -> void {}

attach fn copy(this: counted&) -> counted {
    this.copies += 1;
    return { copies: 0 };
}

fn main() -> void {
    val a: counted = {};
    val b = copy a;
}
// error: copy changes this, but copying or printing a val calls it too: it can only read this
