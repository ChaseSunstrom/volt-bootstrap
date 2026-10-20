// flags: --leak-check --backend c
// suspend inside a defer pauses there on every way out of its scope: a return, a try's early return
// from inside an expression, a break, and the end of the fn; a frame deleted while paused in a
// defer, or before it reached one, finishes its defers without pausing
use std::io;

error oops { BAD, }

fn fallible(fail: bool) -> oops!i32 {
    if (fail) {
        return oops::BAD;
    }
    return 5;
}

struct res { id: i32; }
attach fn delete(this: res&) -> void { std::println("drop {}", this.id); }

async fn by_return(name: str) -> res {
    defer {
        std::println("{} closing", name);
        suspend;
        std::println("{} closed", name);
    }
    return { id: 1 };
}

async fn by_try(fail: bool) -> oops!i32 {
    defer {
        std::println("try closing");
        suspend;
        std::println("try closed");
    }
    val x = 2 + try fallible(fail);
    return x;
}

async fn by_break() -> i32 {
    var total = 0;
    for (i) in 0..5 {
        defer {
            std::println("pass {} ending", i);
            suspend;
        }
        if (i == 2) {
            break;
        }
        total += i;
    }
    return total;
}

async fn by_end(name: str) -> void {
    defer {
        std::println("{} closing", name);
        suspend;
        std::println("{} closed", name);
    }
    std::println("{} body", name);
}

async fn early(name: str) -> void {
    defer {
        std::println("{} closing", name);
        suspend;
        std::println("{} closed", name);
    }
    suspend;
    std::println("{} never", name);
}

fn main() -> void {
    val a = async by_return("ret");
    std::println("paused");
    val r = await a;
    std::println("got {}", r.id);
    val b = async by_try(true);
    std::println("{}", await b catch -1);
    val b2 = async by_try(false);
    std::println("{}", await b2 catch -1);
    val c = async by_break();
    std::println("{}", await c);
    val d = async by_end("end");
    resume d;
    {
        val e = async by_return("cancel");
    }
    {
        val f = async early("early");
    }
}
// expect: ret closing
// expect: paused
// expect: ret closed
// expect: got 1
// expect: try closing
// expect: try closed
// expect: -1
// expect: try closing
// expect: try closed
// expect: 7
// expect: pass 0 ending
// expect: pass 1 ending
// expect: pass 2 ending
// expect: 1
// expect: end body
// expect: end closing
// expect: end closed
// expect: cancel closing
// expect: cancel closed
// expect: drop 1
// expect: early closing
// expect: early closed
// expect: drop 1
