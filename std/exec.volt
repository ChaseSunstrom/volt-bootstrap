// std::exec: several async frames run together. run_all resumes each unfinished frame in turn until
// all have finished; a frame waiting on a Rust future is passed over until the future's waker fires,
// and while every unfinished frame waits, the thread sleeps until one is woken (no polling).
// No OS code or threads: the runtime's await word only (on bare metal nothing sleeps).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace exec {
    // the wake cell a step's pending Rust future named (and cleared), or null: the frame suspended itself
    @attributes([@intrinsic("volt_rt_await_take")])
    fn await_take() -> i32*;
    // whether a wake cell's waker fired since its future's last poll
    @attributes([@intrinsic("volt_rt_await_ready")])
    fn await_ready(cell: i32*) -> bool;
    // the word every waker bumps, and a sleep while it's still seq
    @attributes([@intrinsic("volt_rt_exec_seq")])
    fn exec_seq() -> i32;
    @attributes([@intrinsic("volt_rt_exec_sleep")])
    fn exec_sleep(seq: i32) -> void;

    // resume each unfinished frame of `frames` in rounds until all have finished; one waiting on a
    // waker is resumed once it's woken, and while all of them wait, the thread sleeps
    <T: type>
    public fn run_all(frames: std::vec<T>&) -> void {
        // what each frame's last step waits on (null: nothing, resume it again)
        var cells: std::vec<i32*> = {};
        cells.resize(frames.len, null) catch @panic("out of memory");
        loop {
            val seq = exec_seq();
            var left = false;
            var ran = false;
            for (i) in 0..frames.len {
                if (@done(frames[i])) {
                    continue;
                }
                val c = cells[i];
                if (c != null && !await_ready(c)) {
                    left = true;
                    continue;
                }
                await_take();
                resume frames[i];
                cells[i] = null;
                if (!@done(frames[i])) {
                    left = true;
                    cells[i] = await_take();
                    if (cells[i] == null) {
                        ran = true;
                    }
                }
            }
            if (!left) {
                return;
            }
            if (!ran) {
                // every unfinished frame waits: sleep unless a waker fired since the round began
                exec_sleep(seq);
            }
        }
    }
}
