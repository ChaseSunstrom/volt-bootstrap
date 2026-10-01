---
title: Threads
description: std::thread for threads and what they share, with mutexes, condition variables, atomics, shared<T> and channels.
sidebar:
  order: 5
---

`std::thread` works the same way on Linux, macOS and Windows. It contains no OS code itself. The
runtime starts and joins the system's threads, and it sleeps and wakes on a memory word, which is
a futex on Linux, ulock on macOS and `WaitOnAddress` on Windows. The locks are built on that word,
so a `mutex` allocates nothing.

## Spawning and joining

`std::thread::spawn(f)` runs a closure on a new thread and returns its `thread`. `join()` waits for
the thread to finish. Deleting a `thread` also joins it, so a thread never outlives its handle.

This means a closure can borrow with `&` captures, as long as the handle goes out of scope before
what it borrows. A closure takes ownership of a value captured with `move`. A value captured
plainly is copied into it.

```volt
use std::io;
use std::thread;

fn main() -> !void {
    var total: std::thread::atomic_i64 = {};
    {
        var workers: std::vec<std::thread::thread> = {};
        for (k) in 1..5 {
            try workers.push(try std::thread::spawn(|k, total&| () {
                total.add(k * 10);
            }));
        }
    } // the workers are joined here, before total goes away
    std::println(total.load());

    val name = std::string::from("worker");
    var t = try std::thread::spawn(|move name| () {
        std::println("{} running", name.as_str());
    });
    t.join();
    std::println("joined");
}
// expect: 100
// expect: worker running
// expect: joined
```

`spawn` fails with `spawn_error::OUT_OF_MEMORY` or `spawn_error::REFUSED`, the second when the
system won't start another thread. Like `box`, it takes an optional allocator for the closure's
memory: `spawn(f, my_allocator)`. Call `std::thread::yield_now()` to let other threads run.

## Mutexes

A `mutex<T>` holds a value that only one thread at a time can reach. `lock()` waits until the
mutex is free, then returns a `guard`. `get()` on the guard gives the value, and deleting the guard
unlocks the mutex. `try_lock()` returns null if the mutex is already locked.

```volt
use std::io;
use std::thread;

fn main() -> !void {
    var names: std::thread::mutex<std::vec<i32>> = { value: {} };
    {
        var ts: std::vec<std::thread::thread> = {};
        for (k) in 0..4 {
            try ts.push(try std::thread::spawn(|k, names&| () {
                var g = names.lock();
                g.get().push(k) catch @panic("out of memory");
            }));
        }
    }
    var g = names.lock();
    g.get().items().sort();
    std::println(g.get().items());
}
// expect: { 0, 1, 2, 3 }
```

A guard used as a temporary is unlocked at the end of its statement, so `*counter.lock().get() += 1;`
holds the lock for just that statement. Don't move a mutex while it's locked. Either share it
(`shared<mutex<T>>`) or borrow it, as in the example above.

## Atomics

`atomic_i64` and `atomic_bool` can be changed by several threads at once, without a lock. Both
have `load`, `store` and `swap`. `atomic_i64` also has `add`, `sub` and
`compare_swap(expected, desired)`, which sets the value only if it equals `expected`. `swap`, `add`
and `sub` return the value from before the change. Every operation is sequentially consistent.

## shared&lt;T&gt;

`std::thread::share(value)` puts a value on the heap with a count of its owners. `copy` of a
`shared<T>` adds an owner, and the last owner to go deletes the value, on whichever thread that
is. `get()` reaches the value. To change the value from several threads, put a `mutex` or atomics
inside it.

```volt
use std::io;
use std::thread;

struct config { name: str; }
attach fn delete(this: config&) -> void { std::println("config deleted"); }

fn main() -> !void {
    val c: config = { name: "prod" };
    val s = try std::thread::share(move c);
    {
        var t = try std::thread::spawn(|s| () {
            std::println("thread sees {}", s.get().name);
        });
    }
    std::println("{} owner left", s.count());
}
// expect: thread sees prod
// expect: 1 owner left
// expect: config deleted
```

## Channels

A `channel<T>` passes owned values between threads, first in, first out. A copy of a channel is the
same channel, so give each thread its own copy.

- `send(value)` returns false if the channel is closed. The value is then deleted.
- `recv()` waits for a value. It returns null once the channel is closed and empty.
- `try_recv()` doesn't wait.
- `close()` stops further sends. Receivers still get what was sent before the close.

Values that are never received are deleted along with the last copy of the channel.

```volt
use std::io;
use std::thread;

fn main() -> !void {
    val jobs = try std::thread::channel<std::string>::new();
    val results = try std::thread::channel<i64>::new();
    var worker = try std::thread::spawn(|jobs, results| () {
        while (true) {
            val job = jobs.recv() ?? break;
            results.send(@cast<i64>(job.len()));
        }
        results.close();
    });
    jobs.send(std::string::from("one"));
    jobs.send(std::string::from("three"));
    jobs.close();
    var sum: i64 = 0;
    while (true) {
        sum += results.recv() ?? break;
    }
    std::println(sum);
}
// expect: 8
```

## Condition variables

`cond` lets a thread sleep until another thread changes something. `wait(&guard)` unlocks the
guard's mutex, sleeps, and locks the mutex again before it returns. It can also return without a
notify, so always call it in a loop that checks the condition. `notify_one()` wakes one waiting
thread and `notify_all()` wakes all of them.

```volt
use std::io;
use std::thread;

fn main() -> !void {
    var ready: std::thread::mutex<bool> = { value: false };
    var changed: std::thread::cond = {};
    var waiter = try std::thread::spawn(|ready&, changed&| () {
        var g = ready.lock();
        while (!*g.get()) {
            changed.wait(&g);
        }
        std::println("ready");
    });
    *ready.lock().get() = true;
    changed.notify_all();
    waiter.join();
}
// expect: ready
```

## Printing from threads

Each `println`, `print`, `eprintln` or `eprint` holds the program's output streams for all of its
output, so lines printed by different threads never mix. Printing a value that prints something
itself doesn't deadlock.
