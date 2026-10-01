// std::mem: allocators, box<T> (an owning pointer) and memory errors.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace mem {
    // an allocation that failed
    error mem_error {
        OUT_OF_MEMORY // malloc or realloc returned null
    }

    // libc, through the runtime prelude (so user extern decls of malloc never clash)
    @attributes([@intrinsic("volt_rt_malloc")])
    internal fn c_malloc(size: usize) -> void*;
    @attributes([@intrinsic("volt_rt_realloc")])
    internal fn c_realloc(ptr: void*, size: usize) -> void*;
    @attributes([@intrinsic("volt_rt_free")])
    internal fn c_free(ptr: void*) -> void;

    // What everything in std that owns memory allocates through: box, vec, string, map, set, deque,
    // heap, sorted_map, shared, channel, and the functions that return such values. A failed malloc or
    // realloc returns OUT_OF_MEMORY. Like Zig's, the caller says how big a block is when it resizes or
    // frees it, so an allocator needn't remember.
    trait t_allocator {
        // room for count T's, aligned for T
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*);
        // ptr's block, which holds old T's, resized to count T's (it may move; the first min(old,
        // count) T's come along)
        <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> mem_error!(T*);
        // give back ptr's block, which holds count T's
        <T: type> fn free(this, ptr: T*, count: usize = 1) -> void;
    }

    // malloc, realloc and free from the C library. Empty, so a box using it is just a pointer
    struct default_allocator;

    attach t_allocator -> default_allocator {
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*) {
            val raw = c_malloc(try bytes<T>(count)) ?? return mem_error::OUT_OF_MEMORY;
            return @cast<T*>(raw);
        }
        <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> mem_error!(T*) {
            val raw = c_realloc(ptr as void*, try bytes<T>(count)) ?? return mem_error::OUT_OF_MEMORY;
            return @cast<T*>(raw);
        }
        <T: type> fn free(this, ptr: T*, count: usize = 1) -> void {
            c_free(ptr as void*);
        }
    }

    // count T's in bytes, or OUT_OF_MEMORY when that doesn't fit in a usize
    <T: type>
    internal fn bytes(count: usize) -> mem_error!usize {
        if (@sizeof(T) != 0 && count > (@cast<usize>(0) -% 1) / @sizeof(T)) {
            return mem_error::OUT_OF_MEMORY;
        }
        return count * @sizeof(T);
    }

    // where a block of size bytes aligned to align starts, at or after offset end of the bytes at base
    internal fn align_up(base: usize, end: usize, align: usize) -> usize {
        val at = base + end;
        return end + (align - at % align) % align;
    }

    // move the first n T's from one block to another
    <T: type>
    internal fn move_items(from: T*, to: T*, n: usize) -> void {
        val src = @slice(from, n);
        val dst = @slice(to, n);
        for (i) in 0..n {
            @write(&dst[i], @read(&src[i]));
        }
    }

    // ---------- a fixed buffer ----------

    // Memory from a buffer the program owns (an array on the stack, a global, anything): no heap at
    // all. Blocks are handed out front to back; freeing or resizing the last one gives its room back,
    // other frees keep theirs until reset. Allocate through allocator(); the buffer has to outlive
    // everything allocated from it.
    struct fixed_buffer {
        buf: u8[..];      // the memory
        end: usize = 0;   // bytes in use: the front of buf
        last: usize = 0;  // where the last block starts
    }

    // the allocator for a fixed_buffer (a pointer to it, so every container using it shares its state)
    struct fixed_buffer_allocator {
        fb: fixed_buffer* = null;
    }

    attach t_allocator -> fixed_buffer_allocator {
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*) {
            val fb = this.fb;
            val size = try bytes<T>(count);
            val base = @cast<usize>(fb->buf.ptr);
            val start = align_up(base, fb->end, @alignof(T));
            if (start > fb->buf.len || size > fb->buf.len - start) {
                return mem_error::OUT_OF_MEMORY;
            }
            fb->last = start;
            fb->end = start + size;
            return @cast<T*>(base + start);
        }
        <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> mem_error!(T*) {
            val fb = this.fb;
            val size = try bytes<T>(count);
            val at = @cast<usize>(ptr) - @cast<usize>(fb->buf.ptr);
            // the last block grows or shrinks where it is
            if (at == fb->last && at + old * @sizeof(T) == fb->end) {
                if (size > fb->buf.len - at) {
                    return mem_error::OUT_OF_MEMORY;
                }
                fb->end = at + size;
                return ptr;
            }
            if (count <= old) {
                return ptr;
            }
            val fresh: T* = try this.malloc<T>(count);
            move_items<T>(ptr, fresh, old);
            return fresh;
        }
        <T: type> fn free(this, ptr: T*, count: usize = 1) -> void {
            val fb = this.fb;
            val at = @cast<usize>(ptr) - @cast<usize>(fb->buf.ptr);
            if (at == fb->last && at + count * @sizeof(T) == fb->end) {
                fb->end = at;
            }
        }
    }

    // ---------- an arena ----------

    // a chunk of an arena's memory, followed by its size bytes
    internal struct arena_chunk {
        next: arena_chunk* = null; // the chunk before it
        size: usize = 0;
    }

    // Memory that goes all at once: blocks come from chunks taken from backing, frees do nothing
    // (except for the last block, whose room comes back), and deleting or resetting the arena gives
    // every chunk back. Allocate through allocator(); the arena has to outlive what's allocated from it.
    <B: t_allocator = default_allocator>
    struct arena {
        backing: B = {};             // where the chunks come from
        head: arena_chunk* = null;   // the newest chunk
        end: usize = 0;              // bytes in use in head
        last: usize = 0;             // where the last block in head starts
        total: usize = 0;            // bytes handed out, all chunks
    }

    // the allocator for an arena (a pointer to it, so every container using it shares its state)
    <B: t_allocator = default_allocator>
    struct arena_allocator {
        a: arena<B>* = null;
    }

    <B: t_allocator>
    attach t_allocator -> arena_allocator<B> {
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*) {
            val a = this.a;
            val size = try bytes<T>(count);
            if (a->head != null) {
                val base = @cast<usize>(a->head) + @sizeof(arena_chunk);
                val start = align_up(base, a->end, @alignof(T));
                if (start <= a->head->size && size <= a->head->size - start) {
                    a->last = start;
                    a->end = start + size;
                    a->total += size;
                    return @cast<T*>(base + start);
                }
            }
            // a new chunk: at least 4 KiB, double the last, and room for this block however it aligns
            if (size > (@cast<usize>(0) -% 1) / 4) {
                return mem_error::OUT_OF_MEMORY;
            }
            var want: usize = 4096;
            if (a->head != null && a->head->size * 2 > want) {
                want = a->head->size * 2;
            }
            if (size + @alignof(T) > want) {
                want = size + @alignof(T);
            }
            val raw: u8* = try a->backing.malloc<u8>(@sizeof(arena_chunk) + want);
            val c = @cast<arena_chunk*>(raw);
            @write(c, { next: a->head, size: want });
            a->head = c;
            a->end = 0;
            val base = @cast<usize>(c) + @sizeof(arena_chunk);
            val start = align_up(base, 0, @alignof(T));
            a->last = start;
            a->end = start + size;
            a->total += size;
            return @cast<T*>(base + start);
        }
        <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> mem_error!(T*) {
            val a = this.a;
            val size = try bytes<T>(count);
            if (a->head != null && @cast<usize>(ptr) >= @cast<usize>(a->head) + @sizeof(arena_chunk)) {
                val at = @cast<usize>(ptr) - (@cast<usize>(a->head) + @sizeof(arena_chunk));
                // the last block grows or shrinks where it is, when its chunk has room
                if (at == a->last && at + old * @sizeof(T) == a->end && size <= a->head->size - at) {
                    a->total = a->total - old * @sizeof(T) + size;
                    a->end = at + size;
                    return ptr;
                }
            }
            if (count <= old) {
                return ptr;
            }
            val fresh: T* = try this.malloc<T>(count);
            move_items<T>(ptr, fresh, old);
            return fresh;
        }
        <T: type> fn free(this, ptr: T*, count: usize = 1) -> void {
            val a = this.a;
            if (a->head == null) {
                return;
            }
            val base = @cast<usize>(a->head) + @sizeof(arena_chunk);
            if (@cast<usize>(ptr) >= base && @cast<usize>(ptr) - base == a->last && a->last + count * @sizeof(T) == a->end) {
                a->total -= count * @sizeof(T);
                a->end = a->last;
            }
        }
    }

    // ---------- a failing allocator ----------

    // For testing what happens when memory runs out: the next left allocations (or resizes) come from
    // backing, and every one after them fails. Allocate through allocator().
    <B: t_allocator = default_allocator>
    struct failing {
        left: i64 = 0;   // allocations still allowed
        backing: B = {}; // where those come from
    }

    // the allocator for a failing (a pointer to it, so every container using it shares the count)
    <B: t_allocator = default_allocator>
    struct failing_allocator {
        f: failing<B>* = null;
    }

    <B: t_allocator>
    attach t_allocator -> failing_allocator<B> {
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*) {
            val f = this.f;
            if (f->left <= 0) {
                return mem_error::OUT_OF_MEMORY;
            }
            f->left -= 1;
            return f->backing.malloc<T>(count);
        }
        <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> mem_error!(T*) {
            val f = this.f;
            if (f->left <= 0) {
                return mem_error::OUT_OF_MEMORY;
            }
            f->left -= 1;
            return f->backing.realloc<T>(ptr, old, count);
        }
        <T: type> fn free(this, ptr: T*, count: usize = 1) -> void {
            this.f->backing.free<T>(ptr, count);
        }
    }

    // the owned pointer. keeps its allocator, so it frees with the one that allocated.
    // @owns("ptr"): box is used like a T&, and when it goes out of scope *ptr is deleted first,
    // then box's own delete (below) frees the memory. Any library can make such a type
    <T: type, Allocator: t_allocator = default_allocator>
    @attributes([@owns("ptr")])
    struct box {
        ptr: T*; // raw: the memory the box owns
        allocator: Allocator; // what frees ptr
    }
}

// T::new(value) / T::new(value, allocator): a box holding value
<T: type, Allocator: std::mem::t_allocator = std::mem::default_allocator>
attach fn new(static this: T, value: T, allocator: Allocator = {}) -> std::mem::mem_error!std::mem::box<T, Allocator> {
    val p: T* = try allocator.malloc<T>();
    @write(p, move value); // p is fresh memory: nothing there to delete
    return { ptr: p, allocator: move allocator };
}

// frees a box's memory; runs automatically after *ptr is deleted
<T: type, Allocator: std::mem::t_allocator>
attach fn delete(this: std::mem::box<T, Allocator>&) -> void {
    this.allocator.free<T>(this.ptr);
}

// copy of a box: a new allocation from the same kind of allocator holding a copy of *ptr
<T: type, Allocator: std::mem::t_allocator>
attach fn copy(this: std::mem::box<T, Allocator>&) -> std::mem::box<T, Allocator> {
    val p: T* = this.allocator.malloc<T>() catch @panic("out of memory");
    @write(p, copy *this.ptr);
    return { ptr: p, allocator: copy this.allocator };
}

// the allocator handing out the buffer's memory
attach fn allocator(this: std::mem::fixed_buffer&) -> std::mem::fixed_buffer_allocator {
    return { fb: this };
}

// bytes in use (including any padding for alignment)
attach fn used(this: std::mem::fixed_buffer&) -> usize {
    return this.end;
}

// forget every block: the whole buffer is free again (what was allocated must not be used after)
attach fn reset(this: std::mem::fixed_buffer&) -> void {
    this.end = 0;
    this.last = 0;
}

// the allocator handing out the arena's memory
<B: std::mem::t_allocator>
attach fn allocator(this: std::mem::arena<B>&) -> std::mem::arena_allocator<B> {
    return { a: this };
}

// bytes handed out and not given back
<B: std::mem::t_allocator>
attach fn used(this: std::mem::arena<B>&) -> usize {
    return this.total;
}

// give every chunk back: what was allocated must not be used after
<B: std::mem::t_allocator>
attach fn reset(this: std::mem::arena<B>&) -> void {
    while (this.head != null) {
        val c = this.head;
        this.head = c->next;
        this.backing.free<u8>(@cast<u8*>(c), @sizeof(std::mem::arena_chunk) + c->size);
    }
    this.end = 0;
    this.last = 0;
    this.total = 0;
}

<B: std::mem::t_allocator>
attach fn delete(this: std::mem::arena<B>&) -> void {
    this.reset();
}

// the allocator that counts down its allocations
<B: std::mem::t_allocator>
attach fn allocator(this: std::mem::failing<B>&) -> std::mem::failing_allocator<B> {
    return { f: this };
}
