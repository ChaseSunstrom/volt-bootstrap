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

// cancelled while paused in a loop pass's defer: it finishes that defer and the ones around it,
// and doesn't go back into the loop
async fn loop_cancel() -> void {
    defer { std::println("outer defer"); }
    for (i) in 0..3 {
        defer {
            std::println("pass {} ending", i);
            suspend;
            std::println("pass {} ended", i);
        }
        std::println("pass {}", i);
    }
    std::println("after the loop");
}

// a defer holding a block with a suspending defer of its own
async fn inner_block(name: str) -> void {
    defer {
        {
            defer {
                std::println("{} inner closing", name);
                suspend;
                std::println("{} inner closed", name);
            }
            std::println("{} block", name);
        }
        std::println("{} outer done", name);
    }
    std::println("{} body", name);
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
    {
        val g = async loop_cancel();
    }
    val ib = async inner_block("ib");
    resume ib;
    {
        val ic = async inner_block("ic");
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
// expect: pass 0
// expect: pass 0 ending
// expect: pass 0 ended
// expect: outer defer
// expect: ib body
// expect: ib block
// expect: ib inner closing
// expect: ib inner closed
// expect: ib outer done
// expect: ic body
// expect: ic block
// expect: ic inner closing
// expect: ic inner closed
// expect: ic outer done
// expect: drop 1
