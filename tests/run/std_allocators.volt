// flags: --leak-check
use std::io;
use std::string;
use std::text;
// allocators: std's containers and functions over an arena, a fixed buffer and a failing allocator

extern "C" fn getpid() -> i32;

fn ok(r: std::mem::mem_error!void) -> bool {
    r catch |e| {
        return false;
    };
    return true;
}

fn main() -> !void {
    // an arena: what's allocated from it goes when it does (its containers' frees do nothing)
    {
        var arena: std::mem::arena = {};
        val a = arena.allocator();
        var s = std::string::from("hello", a);
        s.append(", world");
        var v: std::vec<i32, std::mem::arena_allocator> = { allocator: a };
        for (k) in 0..100 {
            try v.push(k);
        }
        var m: std::map<str, i32, std::mem::arena_allocator> = { allocator: a };
        m.put("one", 1);
        m.put("two", 2);
        var st = std::set<i32>::new_in(a); // the wrapping containers take theirs through new_in
        st.add(3);
        st.add(3);
        var d: std::deque<i32, std::mem::arena_allocator> = { allocator: a };
        d.push_back(4);
        d.push_front(3);
        var h = std::heap<i32>::new_in(a);
        h.push(9);
        h.push(5);
        var sm = std::sorted_map<i32, str>::new_in(a);
        sm.put(2, "b");
        sm.put(1, "a");
        std::println("{} {} {} {} {} {} {}", s.as_str(), v.len, m.len, st.len(), *(d.front() ?? return), *(h.peek() ?? return), *(sm.get(1) ?? return));
        // a channel's queue and shared state (one thread here: an arena isn't safe to share between them)
        val ch = try std::thread::channel<std::string<std::mem::arena_allocator>>::new_in(a);
        ch.send(std::string::from("over", a));
        ch.send(std::string::from("the arena", a));
        val first = ch.recv() ?? std::string::from("none", a);
        std::println("{} {}", first.as_str(), arena.used() > 0);

        // functions that return memory take the allocator to return it in
        val parts = "x,y,z".split(",", a);
        val joined = std::text::join(parts.items(), "+", a);
        val up = "shout".to_upper(a);
        val p = std::path::join("dir", "file", a);
        val t = std::time::utc_iso8601(0, a);
        val doc = try std::json::parse("{\"k\": [1, 2]}", a);
        val back = doc.text(a);
        std::println("{} {} {} {} {}", joined.as_str(), up.as_str(), p.as_str(), t.as_str(), back.as_str());

        // a file and a directory listing, read into the arena
        var dir = std::string::from("/tmp/volt-alloc-");
        dir.append_int(getpid());
        try std::fs::create_dir(dir.as_str());
        val f = std::path::join(dir.as_str(), "a.txt", a);
        try std::fs::write_file(f.as_str(), "line 1\nline 2\n");
        val body = try std::fs::read_file(f.as_str(), a);
        val names = try std::fs::list_dir(dir.as_str(), a);
        try std::fs::remove_all(dir.as_str());
        std::println("{} {} {}", body.len(), names.len, arena.used() > 0);
    }

    // a fixed buffer: no heap at all, and it runs out
    {
        var storage: u64[32]; // 256 bytes, aligned for anything up to 8
        var fb: std::mem::fixed_buffer = { buf: @slice(@cast<u8*>(&storage), 256) };
        val a = fb.allocator();
        {
            var v: std::vec<i64, std::mem::fixed_buffer_allocator> = { allocator: a };
            var pushed = 0;
            var full = false;
            for (k) in 0..100 {
                v.push(k) catch |e| {
                    full = true;
                    break;
                };
                pushed += 1;
            }
            // it grew in place (each growth was the last allocation) to fill the buffer exactly
            std::println("{} {} {}", pushed, full, fb.used());
        }
        // what's freed last is given back, so the buffer is empty again
        var s = std::string::from("fits", a);
        std::println("{} {}", s.as_str(), fb.used());
    }

    // a failing allocator: the first allocation works, then every one fails
    {
        var fail: std::mem::failing = { left: 1 };
        val a = fail.allocator();
        var v: std::vec<i32, std::mem::failing_allocator> = { allocator: a };
        try v.push(1); // the one that works
        var s = std::string::from("", a);
        var m: std::map<i32, i32, std::mem::failing_allocator> = { allocator: a };
        var d: std::deque<i32, std::mem::failing_allocator> = { allocator: a };
        std::println("{} {} {} {} {} {} {}", v.len, ok(v.reserve(1000)), ok(s.reserve(10)), ok(m.reserve(8)), ok(d.reserve(8)), ok(s.reserve(0)), fail.left);
    }
}
// expect: hello, world 100 2 1 3 5 a
// expect: over true
// expect: x+y+z SHOUT dir/file 1970-01-01T00:00:00Z {"k":[1,2]}
// expect: 14 1 true
// expect: 32 true 256
// expect: fits 4
// expect: 1 false false false false true 0
