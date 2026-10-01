// std::time: the monotonic clock (for measuring), the wall clock, sleeping, durations, and UTC dates
// in ISO 8601.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace time {
    // a span of time
    struct duration {
        ns: i64; // nanoseconds
    }

    // n nanoseconds
    fn nanos(n: i64) -> duration {
        return { ns: n };
    }

    // n microseconds
    fn micros(n: i64) -> duration {
        return { ns: n * 1000 };
    }

    // n milliseconds
    fn millis(n: i64) -> duration {
        return { ns: n * 1000000 };
    }

    // n seconds
    fn secs(n: i64) -> duration {
        return { ns: n * 1000000000 };
    }

    // a point on the monotonic clock: it never jumps back (the wall clock can), and only differences
    // between instants mean anything
    struct instant {
        ns: i64; // nanoseconds since some fixed point (boot, usually)
    }

    // C's struct timespec: seconds and nanoseconds, two 64-bit fields on 64-bit Linux
    struct timespec {
        sec: i64;
        nsec: i64;
    }

    internal extern "C" fn clock_gettime(clock: i32, out: timespec*) -> i32;
    internal extern "C" fn nanosleep(want: timespec*, left: timespec*) -> i32;
    internal extern "C" fn __errno_location() -> i32&;

    // clock id's time in nanoseconds
    // ponytail: Linux's clock ids (0 realtime, 1 monotonic); other systems number them differently
    internal fn clock(id: i32) -> i64 {
        var t: timespec = { sec: 0, nsec: 0 };
        clock_gettime(id, &t);
        return t.sec * 1000000000 + t.nsec;
    }

    // now, on the monotonic clock
    fn now() -> instant {
        return { ns: clock(1) };
    }

    // the wall clock: nanoseconds since 1970-01-01 00:00 UTC
    fn unix_nanos() -> i64 {
        return clock(0);
    }

    // wait for at least d
    fn sleep(d: duration) -> void {
        if (d.ns <= 0) {
            return;
        }
        var want: timespec = { sec: d.ns / 1000000000, nsec: d.ns % 1000000000 };
        var left: timespec = { sec: 0, nsec: 0 };
        // interrupted by a signal (EINTR): sleep what's left
        while (nanosleep(&want, &left) != 0 && *__errno_location() == 4) {
            want = left;
        }
    }

    // a time on the wall clock (nanoseconds since 1970, as unix_nanos gives) as UTC ISO 8601:
    // "2026-09-30T12:34:56Z", with ".789" milliseconds when there are any
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn utc_iso8601(unix_ns: i64, allocator: A = {}) -> std::string<A> {
        // floor division, so times before 1970 count back from it
        var secs = unix_ns / 1000000000;
        var frac = unix_ns % 1000000000;
        if (frac < 0) {
            frac += 1000000000;
            secs -= 1;
        }
        var days = secs / 86400;
        var rem = secs % 86400;
        if (rem < 0) {
            rem += 86400;
            days -= 1;
        }
        // the date from days since 1970 (Howard Hinnant's civil_from_days)
        val z = days + 719468;
        var era = z / 146097;
        if (z < 0 && z % 146097 != 0) {
            era -= 1;
        }
        val doe = z - era * 146097;
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        val mp = (5 * doy + 2) / 153;
        val day = doy - (153 * mp + 2) / 5 + 1;
        var month = mp + 3;
        if (mp >= 10) {
            month = mp - 9;
        }
        var year = yoe + era * 400;
        if (month <= 2) {
            year += 1;
        }
        var out = std::string::new_in(move allocator);
        std::fmt::write(&out, "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}", year, month, day, rem / 3600, rem / 60 % 60, rem % 60);
        val ms = frac / 1000000;
        if (ms != 0) {
            std::fmt::write(&out, ".{:03}", ms);
        }
        out.push('Z');
        return move out;
    }
}

// how long ago this was, on the monotonic clock
attach fn elapsed(this: std::time::instant&) -> std::time::duration {
    return { ns: std::time::now().ns - this.ns };
}

// the time from earlier to this
attach fn since(this: std::time::instant&, earlier: std::time::instant) -> std::time::duration {
    return { ns: this.ns - earlier.ns };
}

// the duration in nanoseconds
attach fn as_nanos(this: std::time::duration&) -> i64 {
    return this.ns;
}

// the duration in whole microseconds
attach fn as_micros(this: std::time::duration&) -> i64 {
    return this.ns / 1000;
}

// the duration in whole milliseconds
attach fn as_millis(this: std::time::duration&) -> i64 {
    return this.ns / 1000000;
}

// the duration in whole seconds
attach fn as_secs(this: std::time::duration&) -> i64 {
    return this.ns / 1000000000;
}

// the duration in seconds, with the fraction
attach fn as_secs_f64(this: std::time::duration&) -> f64 {
    return @cast<f64>(this.ns) / 1000000000.0;
}
