// std::thread: threads, and what they share: mutex<T> (a lock around a value, reached through a
// guard), cond (a condition variable), atomics, shared<T> (one value with an atomic count of its
// copies) and channel<T> (owned values passed between threads).
// No OS code here: the runtime starts and joins the system's threads and sleeps and wakes on a word
// (a futex on Linux, ulock on macOS, WaitOnAddress on Windows); locks are built on that word.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace thread {
    // why spawn failed
    public error spawn_error {
        OUT_OF_MEMORY, // no memory for the thread's closure
        REFUSED        // the system wouldn't start another thread
    }

    @attributes([@intrinsic("volt_rt_thread_start")])
    fn rt_start(job: void*, handle: u64&) -> i32;
    @attributes([@intrinsic("volt_rt_thread_join")])
    fn rt_join(handle: u64) -> void;
    @attributes([@intrinsic("volt_rt_thread_yield")])
    fn rt_yield() -> void;
    // sleep while *word == expected (it can also return early: check again)
    @attributes([@intrinsic("volt_rt_wait")])
    fn rt_wait(word: i32&, expected: i32) -> void;
    // wake one (or all) of the threads sleeping on word
    @attributes([@intrinsic("volt_rt_wake")])
    fn rt_wake(word: i32&, all: bool) -> void;

    // sequentially consistent atomics; add gives the value before
    @attributes([@intrinsic("volt_rt_atomic_load32")])
    fn load32(p: i32&) -> i32;
    @attributes([@intrinsic("volt_rt_atomic_store32")])
    fn store32(p: i32&, v: i32) -> void;
    @attributes([@intrinsic("volt_rt_atomic_swap32")])
    fn swap32(p: i32&, v: i32) -> i32;
    @attributes([@intrinsic("volt_rt_atomic_add32")])
    fn add32(p: i32&, v: i32) -> i32;
    @attributes([@intrinsic("volt_rt_atomic_cas32")])
    fn cas32(p: i32&, expected: i32, desired: i32) -> bool;
    @attributes([@intrinsic("volt_rt_atomic_load64")])
    fn load64(p: i64&) -> i64;
    @attributes([@intrinsic("volt_rt_atomic_store64")])
    fn store64(p: i64&, v: i64) -> void;
    @attributes([@intrinsic("volt_rt_atomic_swap64")])
    fn swap64(p: i64&, v: i64) -> i64;
    @attributes([@intrinsic("volt_rt_atomic_add64")])
    fn add64(p: i64&, v: i64) -> i64;
    @attributes([@intrinsic("volt_rt_atomic_cas64")])
    fn cas64(p: i64&, expected: i64, desired: i64) -> bool;

    // A running thread. Deleting it joins it (waits for it to finish), so a thread never outlives its
    // handle, and what its closure borrows (& captures) only has to outlive the handle.
    public struct thread {
        handle: u64 = 0;
        running: bool = false; // false: nothing to join (a default thread, or one joined already)
    }

    // what a new thread runs, in memory from allocator: the entry first (the runtime calls it with
    // this memory; extern keeps the fields in order), then the closure and the allocator that frees it
    <F: type, A: std::mem::allocator>
    extern struct job {
        run: extern "C" fn(void*) -> void;
        f: F;
        allocator: A;
    }

    // on the new thread: move the closure and the allocator out, free the job, run the closure
    <F: type, A: std::mem::allocator>
    fn run_job(p: void*) -> void {
        val jp = @cast<job<F, A>*>(p);
        val f: F = @read(&jp->f);
        var allocator: A = @read(&jp->allocator);
        allocator.free<job<F, A>>(jp);
        f();
    }

    // run f, a closure with no parameters, on a new thread. f is moved there: what it captures by
    // value or with move belongs to the thread
    <F: type, A: std::mem::allocator = std::mem::default_allocator>
    public fn spawn(f: F, allocator: A = {}) -> spawn_error!thread {
        val p: job<F, A>* = allocator.malloc<job<F, A>>() catch return spawn_error::OUT_OF_MEMORY;
        @write(p, { run: run_job<F, A>, f: move f, allocator: move allocator });
        var t: thread = {};
        if (rt_start(@cast<void*>(p), &t.handle) != 0) {
            // not started: take the closure back (it's deleted here) and free the job
            val back: F = @read(&p->f);
            var a: A = @read(&p->allocator);
            a.free<job<F, A>>(p);
            return spawn_error::REFUSED;
        }
        t.running = true;
        return t;
    }

    // let another thread run
    public fn yield_now() -> void {
        rt_yield();
    }

    // take the lock on w: 0 free, 1 held, 2 held and someone may be sleeping on it
    fn lock_word(w: i32&) -> void {
        if (cas32(w, 0, 1)) {
            return;
        }
        lock_contended(w);
    }

    // take it, marking that someone may be sleeping (after a wait, others may be)
    fn lock_contended(w: i32&) -> void {
        while (swap32(w, 2) != 0) {
            rt_wait(w, 2);
        }
    }

    fn unlock_word(w: i32&) -> void {
        if (swap32(w, 0) == 2) {
            rt_wake(w, false);
        }
    }

    // A lock around a value: lock() waits for it and gives a guard, through which the value is reached;
    // deleting the guard unlocks it. Don't move a mutex while it's locked (share it: shared<mutex<T>>,
    // or borrow it from a thread whose handle goes first).
    <T: type>
    public struct mutex {
        word: i32 = 0; // 0 free, 1 locked, 2 locked and someone may be waiting
        value: T;      // what it guards
    }

    // the lock on a mutex, held until the guard is deleted
    <T: type>
    public struct guard {
        m: mutex<T>*;
    }

    // A condition variable: wait(guard) unlocks the guard's mutex and sleeps until notified, then locks
    // it again. It can wake without a notify, so wait in a loop that checks what it's waiting for.
    public struct cond {
        seq: i32 = 0; // bumped by every notify
    }

    // an i64 that threads can change at the same time
    public struct atomic_i64 {
        value: i64 = 0;
    }

    // a bool that threads can change at the same time
    public struct atomic_bool {
        value: i32 = 0;
    }

    // a shared value and the number of shared<T>s pointing at it
    <T: type>
    struct shared_box {
        count: i64;
        value: T;
    }

    // One value with several owners, on any threads: copy makes another owner (the count goes up
    // atomically), and the value is deleted with the last one. Reach the value with get(); to change it
    // from several threads, share a mutex<T> or atomics.
    <T: type, Allocator: std::mem::allocator = std::mem::default_allocator>
    public struct shared {
        ptr: shared_box<T>*; // null in an empty (default) shared
        allocator: Allocator; // what frees it
    }

    // value in a new shared<T>, its only owner so far
    <T: type, A: std::mem::allocator = std::mem::default_allocator>
    public fn share(value: T, allocator: A = {}) -> std::mem::mem_error!shared<T, A> {
        val p: shared_box<T>* = try allocator.malloc<shared_box<T>>();
        @write(p, { count: 1, value: move value });
        return { ptr: p, allocator: move allocator };
    }

    // what a channel holds: values sent and not yet received, and whether it's closed
    <T: type, A: std::mem::allocator>
    struct chan_items {
        queue: std::deque<T, A>;
        closed: bool;
    }

    <T: type, A: std::mem::allocator>
    struct chan_state {
        items: mutex<chan_items<T, A>>;
        ready: cond; // notified on a send or a close
    }

    // Owned values passed between threads, first in first out. A copy of a channel is the same channel
    // (give each thread its own copy); it's deleted, with whatever was never received, with the last.
    // Its queue and shared state come from Allocator.
    <T: type, Allocator: std::mem::allocator = std::mem::default_allocator>
    public struct channel {
        state: shared<chan_state<T, Allocator>, Allocator>;
    }
}

// wait for the thread to finish (again: nothing)
public attach fn join(this: std::thread::thread&) -> void {
    if (this.running) {
        std::thread::rt_join(this.handle);
        this.running = false;
    }
}

public attach fn delete(this: std::thread::thread&) -> void {
    this.join();
}

// wait for the lock and take it: the guard reaches the value, and unlocks when it's deleted
<T: type>
public attach fn lock(this: std::thread::mutex<T>&) -> std::thread::guard<T> {
    std::thread::lock_word(&this.word);
    return { m: this };
}

// the lock if it's free now, else null
<T: type>
public attach fn try_lock(this: std::thread::mutex<T>&) -> std::thread::guard<T>? {
    if (std::thread::cas32(&this.word, 0, 1)) {
        val g: std::thread::guard<T> = { m: this };
        return g;
    }
    return null;
}

// the locked value
<T: type>
public attach fn get(this: std::thread::guard<T>&) -> T& {
    return &this.m->value;
}

<T: type>
public attach fn delete(this: std::thread::guard<T>&) -> void {
    std::thread::unlock_word(&this.m->word);
}

// unlock g's mutex, sleep until notified (or not: check again), lock it again
<T: type>
public attach fn wait(this: std::thread::cond&, g: std::thread::guard<T>&) -> void {
    val seen = std::thread::load32(&this.seq);
    std::thread::unlock_word(&g.m->word);
    std::thread::rt_wait(&this.seq, seen);
    std::thread::lock_contended(&g.m->word);
}

// wake one waiting thread
public attach fn notify_one(this: std::thread::cond&) -> void {
    std::thread::add32(&this.seq, 1);
    std::thread::rt_wake(&this.seq, false);
}

// wake every waiting thread
public attach fn notify_all(this: std::thread::cond&) -> void {
    std::thread::add32(&this.seq, 1);
    std::thread::rt_wake(&this.seq, true);
}

public attach fn load(this: std::thread::atomic_i64&) -> i64 {
    return std::thread::load64(&this.value);
}

public attach fn store(this: std::thread::atomic_i64&, v: i64) -> void {
    std::thread::store64(&this.value, v);
}

// add n; the value before
public attach fn add(this: std::thread::atomic_i64&, n: i64) -> i64 {
    return std::thread::add64(&this.value, n);
}

// subtract n; the value before
public attach fn sub(this: std::thread::atomic_i64&, n: i64) -> i64 {
    return std::thread::add64(&this.value, 0 -% n);
}

// set it to v; the value before
public attach fn swap(this: std::thread::atomic_i64&, v: i64) -> i64 {
    return std::thread::swap64(&this.value, v);
}

// set it to desired if it's expected; whether it was
public attach fn compare_swap(this: std::thread::atomic_i64&, expected: i64, desired: i64) -> bool {
    return std::thread::cas64(&this.value, expected, desired);
}

public attach fn load(this: std::thread::atomic_bool&) -> bool {
    return std::thread::load32(&this.value) != 0;
}

public attach fn store(this: std::thread::atomic_bool&, v: bool) -> void {
    std::thread::store32(&this.value, @cast<i32>(v));
}

// set it to v; the value before
public attach fn swap(this: std::thread::atomic_bool&, v: bool) -> bool {
    return std::thread::swap32(&this.value, @cast<i32>(v)) != 0;
}

// the shared value
<T: type, A: std::mem::allocator>
public attach fn get(this: std::thread::shared<T, A>&) -> T& {
    return &this.ptr->value;
}

// how many shared<T>s point at the value (on several threads, it may change right after)
<T: type, A: std::mem::allocator>
public attach fn count(this: std::thread::shared<T, A>&) -> i64 {
    return std::thread::load64(&this.ptr->count);
}

// another owner of the same value
<T: type, A: std::mem::allocator>
public attach fn copy(this: std::thread::shared<T, A>&) -> std::thread::shared<T, A> {
    if (this.ptr != null) {
        std::thread::add64(&this.ptr->count, 1);
    }
    return { ptr: this.ptr, allocator: copy this.allocator };
}

// one owner fewer; the last one deletes the value and frees its memory
<T: type, A: std::mem::allocator>
public attach fn delete(this: std::thread::shared<T, A>&) -> void {
    if (this.ptr == null || std::thread::add64(&this.ptr->count, -1) != 1) {
        return;
    }
    val last: T = @read(&this.ptr->value); // deleted when this returns
    this.allocator.free<std::thread::shared_box<T>>(this.ptr);
}

// a new, empty channel
<T: type>
public attach fn new(static this: std::thread::channel<T>) -> std::mem::mem_error!std::thread::channel<T> {
    val a: std::mem::default_allocator = {};
    return std::thread::channel<T>::new_in(a);
}

// a new, empty channel whose memory comes from allocator
<T: type, A: std::mem::allocator>
public attach fn new_in(static this: std::thread::channel<T>, allocator: A) -> std::mem::mem_error!std::thread::channel<T, A> {
    val st: std::thread::chan_state<T, A> = { items: { value: { queue: { allocator: copy allocator }, closed: false } }, ready: {} };
    return { state: try std::thread::share(move st, move allocator) };
}

// send value to whoever receives; false if the channel is closed (then value is deleted)
<T: type, A: std::mem::allocator>
public attach fn send(this: std::thread::channel<T, A>&, value: T) -> bool {
    val st = this.state.get();
    {
        var g = st.items.lock();
        if (g.get().closed) {
            return false;
        }
        g.get().queue.push_back(move value);
    }
    st.ready.notify_one();
    return true;
}

// the next value, waiting for one if there's none yet; null once the channel is closed and empty
<T: type, A: std::mem::allocator>
public attach fn recv(this: std::thread::channel<T, A>&) -> T? {
    val st = this.state.get();
    var g = st.items.lock();
    while (g.get().queue.len == 0 && !g.get().closed) {
        st.ready.wait(&g);
    }
    return g.get().queue.pop_front();
}

// the next value if one is waiting, else null
<T: type, A: std::mem::allocator>
public attach fn try_recv(this: std::thread::channel<T, A>&) -> T? {
    var g = this.state.get().items.lock();
    return g.get().queue.pop_front();
}

// no more sends: receivers get what's left, then null
<T: type, A: std::mem::allocator>
public attach fn close(this: std::thread::channel<T, A>&) -> void {
    val st = this.state.get();
    {
        var g = st.items.lock();
        g.get().closed = true;
    }
    st.ready.notify_all();
}
