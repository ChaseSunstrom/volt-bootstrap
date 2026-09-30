// flags: --leak-check
use std::io;

struct res { id: i32; }
attach fn delete(this: res&) -> void { std::println("drop {}", this.id); }

// owned locals and params live in the frame; a cancelled frame deletes what's still live
async fn holder(r: res, n: i32) -> !res {
    val b = try i32::new(n);
    val keep: res = { id: n + 1 };
    suspend;
    std::println("resumed {} {} {}", r.id, *b, keep.id);
    return move keep;
}

async fn fails(n: i32) -> !i32 {
    val b = try i32::new(n);
    suspend;
    if (n > 5) {
        return error;
    }
    return *b;
}

async fn ranged(xs: i32[..]) -> i32 {
    var total = 0;
    for (x, i) in xs {
        total += x * @cast<i32>(i);
        suspend;
    }
    return total;
}

fn main() -> !void {
    {
        val h = async holder({ id: 1 }, 10);
        resume h;
        val got = try await h;
        std::println("got {}", got.id);
    }
    {
        val h = async holder({ id: 20 }, 30);
        std::println("cancel");
    }
    val f = async fails(3);
    std::println(try await f);
    val g = async fails(9);
    val r = await g catch -1;
    std::println(r);
    val arr: i32[] = { 1, 2, 3, 4 };
    val s = async ranged(arr[..]);
    resume s;
    resume s;
    std::println(await s);
}
// expect: resumed 1 10 11
// expect: drop 1
// expect: got 11
// expect: drop 11
// expect: cancel
// expect: drop 31
// expect: drop 20
// expect: 3
// expect: -1
// expect: 20
