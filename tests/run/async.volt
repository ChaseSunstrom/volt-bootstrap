use std::io;

async fn test_async() -> i32 {
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < 10) {
        sum = sum + i;
        i++;
    }
    return sum;
}

async fn test_suspend_resume() -> i32 {
    var result: i32 = 0;
    result = 10;
    suspend;
    result = result + 5;
    suspend;
    result = result * 2;
    return result;
}

async fn async_caller() -> i32 {
    val a = await test_async();
    val frame = async test_suspend_resume();
    resume frame;
    resume frame;
    return a + await frame;
}

// a generator: params, for-loop state and a match all live across suspends
async fn count(from: i32, to: i32, out: i32&) -> void {
    for (i) in from..to {
        *out = i;
        suspend;
    }
    match (to - from) {
        0 => { *out = -1; },
        n => { suspend; *out = n * 100; },
    }
}

async fn stepper(label: str) -> str {
    defer std::println("deferred {}", label);
    std::println("{} start", label);
    suspend;
    std::println("{} middle", label);
    suspend;
    return label;
}

fn main() -> void {
    std::println(async_caller());   // 45 + 30
    std::println(test_async());     // a plain call runs it to the end

    var out: i32 = 0;
    val g = async count(3, 6, &out);
    std::println(out);              // 3: ran to the first suspend
    resume g;
    std::println(out);
    resume g;
    std::println(out);
    resume g;                       // loop done, match arm suspends
    std::println(out);
    resume g;
    std::println(out);              // 300
    await g;

    val s = async stepper("a");
    resume s;
    std::println(await s);
    {
        val t = async stepper("b"); // never finished: deleting it runs its defers
    }
    std::println("end");
}
// expect: 75
// expect: 45
// expect: 3
// expect: 4
// expect: 5
// expect: 5
// expect: 300
// expect: a start
// expect: a middle
// expect: deferred a
// expect: a
// expect: b start
// expect: deferred b
// expect: end
