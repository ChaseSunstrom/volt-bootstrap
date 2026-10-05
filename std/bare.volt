// std on bare metal (voltc --target ..-none): the runtime the compiler's code calls, in Volt instead of
// C. Panics, bounds and printing go to the board's volt_console_write; the program ends in the board's
// volt_exit (voltc's start code has defaults for both). Memory comes from a heap between the linker
// script's __heap_start and __heap_end. It also gives what LLVM calls for copies, fills, 64-bit
// division and floating point on 32-bit cores (and division, 64-bit shifts and multiplies on a
// Cortex-M0), which a C library and libgcc would.
// (Part of package std: the package loader wraps every file in `namespace std`.)

@attributes([@cfg("os", "none")])
namespace bare {
    // the board's hooks (voltc's start code jumps from these names to volt_console_write and
    // volt_exit, which the program defines), and the heap's bounds from the linker script
    public extern "C" fn volt_hook_console_write(p: u8*, n: usize) -> void;
    public extern "C" fn volt_hook_exit(code: i32) -> never;
    public extern "C" fn volt_heap_start() -> u8*;
    public extern "C" fn volt_heap_end() -> u8*;

    public fn put(s: str) -> void {
        volt_hook_console_write(@cast<u8*>(s.ptr), s.len);
    }

    public fn put_cstr(c: cstr) -> void {
        val p = @cast<u8*>(c);
        var n: usize = 0;
        while (p[n] != 0) {
            n += 1;
        }
        volt_hook_console_write(p, n);
    }

    public fn put_num(v: u64) -> void {
        var buf: u8[20];
        var i: usize = 20;
        var x = v;
        loop {
            i -= 1;
            buf[i] = @cast<u8>(x % 10) + '0';
            x /= 10;
            if (x == 0) {
                break;
            }
        }
        volt_hook_console_write(&buf[i], 20 - i);
    }

    // ---- what the compiler's checks call ----

    export fn volt_panic(msg: cstr, loc: cstr) -> never {
        put_cstr(loc);
        put(": panic: ");
        put_cstr(msg);
        put("\n");
        volt_hook_exit(101);
    }

    export fn volt_panic_str(msg: str, loc: cstr) -> never {
        put_cstr(loc);
        put(": panic: ");
        put(msg);
        put("\n");
        volt_hook_exit(101);
    }

    export fn volt_bounds(i: usize, len: usize, loc: cstr) -> never {
        put_cstr(loc);
        put(": panic: index ");
        put_num(@cast<u64>(i));
        put(" out of bounds (len ");
        put_num(@cast<u64>(len));
        put(")\n");
        volt_hook_exit(101);
    }

    // ---- printing: a sink is where print's text goes (the console, or a writer std::format made) ----

    public struct sink {
        write: extern "C" fn(void*, str) -> void;
        ctx: void*;
    }

    public extern "C" fn to_console(ctx: void*, s: str) -> void {
        put(s);
    }

    public var console_sink: sink = { write: to_console, ctx: null };

    export fn volt_stdout() -> void* {
        return @cast<void*>(&console_sink);
    }

    export fn volt_stderr() -> void* {
        return @cast<void*>(&console_sink);
    }

    // one core, no threads: nothing to hold
    export fn volt_lock_out() -> void {}
    export fn volt_unlock_out() -> void {}

    export fn volt_put(s: void*, p: cstr, n: usize) -> void {
        if (n > 0) {
            val k = @cast<sink*>(s);
            k->write(k->ctx, @cast<str>(@slice(@cast<u8*>(p), n)));
        }
    }

    export fn volt_print_str(s: void*, t: str) -> void {
        volt_put(s, @cast<cstr>(t.ptr), t.len);
    }

    // ---- the heap: first fit over a free list, carving new blocks off the top ----
    // ponytail: freed blocks aren't merged, so a long-running program that frees many sizes can
    // fragment; merge neighbours when that matters

    // a block's header: its whole size, and while it's free the next free block
    public struct block {
        size: usize;
        next: block*;
    }

    public val HEADER: usize = 16; // keeps what a block holds 16-byte aligned

    public var heap_top: usize = 0;
    public var heap_limit: usize = 0;
    public var free_blocks: block* = null;

    export fn volt_rt_malloc(n: usize) -> void* {
        val need = (n + HEADER + 15) / 16 * 16;
        var prev: block* = null;
        var b = free_blocks;
        while (b != null) {
            if (b->size >= need) {
                if (prev != null) {
                    prev->next = b->next;
                } else {
                    free_blocks = b->next;
                }
                return @cast<void*>(@cast<usize>(b) + HEADER);
            }
            prev = b;
            b = b->next;
        }
        if (heap_top == 0) {
            heap_top = (@cast<usize>(volt_heap_start()) + 15) / 16 * 16;
            heap_limit = @cast<usize>(volt_heap_end());
        }
        if (need > heap_limit - heap_top) {
            return null;
        }
        val at = heap_top;
        heap_top += need;
        val blk = @cast<block*>(at);
        blk->size = need;
        return @cast<void*>(at + HEADER);
    }

    export fn volt_rt_free(p: void*) -> void {
        if (p == null) {
            return;
        }
        val b = @cast<block*>(@cast<usize>(p) - HEADER);
        b->next = free_blocks;
        free_blocks = b;
    }

    export fn volt_rt_realloc(p: void*, n: usize) -> void* {
        if (p == null) {
            return volt_rt_malloc(n);
        }
        val b = @cast<block*>(@cast<usize>(p) - HEADER);
        val have = b->size - HEADER;
        if (n <= have) {
            return p;
        }
        val q = volt_rt_malloc(n);
        if (q != null) {
            val from = @cast<u8*>(p);
            val to = @cast<u8*>(q);
            for (i) in 0..have {
                to[i] = from[i];
            }
            volt_rt_free(p);
        }
        return q;
    }

    // float % (LLVM's frem), which LLVM makes a call to the C library's fmod or fmodf
    export fn fmod(x: f64, y: f64) -> f64 {
        return std::math::portable::fmod(x, y);
    }

    // float % on f32
    export fn fmodf(x: f32, y: f32) -> f32 {
        return std::math::portable::fmod(x, y);
    }

    // what LLVM calls for 64-bit division on 32-bit cores (std::softint)
    @attributes([@cfg("pointer_bits", "32")])
    namespace div32 {
        export fn __udivdi3(a: u64, b: u64) -> u64 { return std::softint::udivmod64(a, b, null); }
        export fn __umoddi3(a: u64, b: u64) -> u64 {
            var r: u64 = 0;
            std::softint::udivmod64(a, b, &r);
            return r;
        }
        export fn __divdi3(a: i64, b: i64) -> i64 { return std::softint::sdivmod64(a, b, null); }
        export fn __moddi3(a: i64, b: i64) -> i64 {
            var r: i64 = 0;
            std::softint::sdivmod64(a, b, &r);
            return r;
        }
    }

    // and on a Cortex-M0, which has no divide instruction and shifts and multiplies 64-bit numbers
    // in software too
    @attributes([@cfg("target", "thumbv6m-none")])
    namespace v6m {
        export fn __udivsi3(a: u32, b: u32) -> u32 { return std::softint::udivmod32(a, b, null); }
        export fn __umodsi3(a: u32, b: u32) -> u32 {
            var r: u32 = 0;
            std::softint::udivmod32(a, b, &r);
            return r;
        }
        export fn __divsi3(a: i32, b: i32) -> i32 { return std::softint::sdivmod32(a, b, null); }
        export fn __modsi3(a: i32, b: i32) -> i32 {
            var r: i32 = 0;
            std::softint::sdivmod32(a, b, &r);
            return r;
        }
        export fn __ashldi3(a: u64, s: i32) -> u64 { return std::softint::shl64(a, @cast<u32>(s)); }
        export fn __lshrdi3(a: u64, s: i32) -> u64 { return std::softint::lshr64(a, @cast<u32>(s)); }
        export fn __ashrdi3(a: i64, s: i32) -> i64 { return std::softint::ashr64(a, @cast<u32>(s)); }
        export fn __muldi3(a: u64, b: u64) -> u64 { return std::softint::mul64(a, b); }
    }

    // ---- the C library's memory functions, which LLVM calls for copies and fills (size_t is the
    // pointer's size) ----

    @attributes([@cfg("pointer_bits", "32")])
    namespace mem32 {
        export fn memcpy(d: u8*, s: u8*, n: u32) -> u8* {
            var i: u32 = 0;
            while (i < n) {
                d[i] = s[i];
                i += 1;
            }
            return d;
        }
        export fn memmove(d: u8*, s: u8*, n: u32) -> u8* {
            if (@cast<usize>(d) < @cast<usize>(s)) {
                return memcpy(d, s, n);
            }
            var i = n;
            while (i > 0) {
                i -= 1;
                d[i] = s[i];
            }
            return d;
        }
        export fn memset(d: u8*, c: i32, n: u32) -> u8* {
            var i: u32 = 0;
            while (i < n) {
                d[i] = @cast<u8>(c);
                i += 1;
            }
            return d;
        }
        export fn memcmp(a: u8*, b: u8*, n: u32) -> i32 {
            var i: u32 = 0;
            while (i < n) {
                if (a[i] != b[i]) {
                    return @cast<i32>(a[i]) - @cast<i32>(b[i]);
                }
                i += 1;
            }
            return 0;
        }
        export fn bcmp(a: u8*, b: u8*, n: u32) -> i32 { return memcmp(a, b, n); }
    }

    @attributes([@cfg("pointer_bits", "64")])
    namespace mem64 {
        export fn memcpy(d: u8*, s: u8*, n: usize) -> u8* {
            for (i) in 0..n {
                d[i] = s[i];
            }
            return d;
        }
        export fn memmove(d: u8*, s: u8*, n: usize) -> u8* {
            if (@cast<usize>(d) < @cast<usize>(s)) {
                return memcpy(d, s, n);
            }
            var i = n;
            while (i > 0) {
                i -= 1;
                d[i] = s[i];
            }
            return d;
        }
        export fn memset(d: u8*, c: i32, n: usize) -> u8* {
            for (i) in 0..n {
                d[i] = @cast<u8>(c);
            }
            return d;
        }
        export fn memcmp(a: u8*, b: u8*, n: usize) -> i32 {
            for (i) in 0..n {
                if (a[i] != b[i]) {
                    return @cast<i32>(a[i]) - @cast<i32>(b[i]);
                }
            }
            return 0;
        }
        export fn bcmp(a: u8*, b: u8*, n: usize) -> i32 { return memcmp(a, b, n); }
    }

    // ---- floating point on cores without an FPU (std::softfloat), under the names LLVM calls ----

    @attributes([@cfg("pointer_bits", "32")])
    namespace soft {
        // a float's bits and back (register moves: no float instructions)
        public fn b64(v: f64) -> u64 { return @bitcast<u64>(v); }
        public fn f64_of(b: u64) -> f64 { return @bitcast<f64>(b); }
        public fn b32(v: f32) -> u32 { return @bitcast<u32>(v); }
        public fn f32_of(b: u32) -> f32 { return @bitcast<f32>(b); }

        export fn __adddf3(a: f64, b: f64) -> f64 { return f64_of(std::softfloat::add64(b64(a), b64(b))); }
        export fn __subdf3(a: f64, b: f64) -> f64 { return f64_of(std::softfloat::sub64(b64(a), b64(b))); }
        export fn __muldf3(a: f64, b: f64) -> f64 { return f64_of(std::softfloat::mul64(b64(a), b64(b))); }
        export fn __divdf3(a: f64, b: f64) -> f64 { return f64_of(std::softfloat::div64(b64(a), b64(b))); }
        export fn __negdf2(a: f64) -> f64 { return f64_of(b64(a) ^ std::softfloat::SIGN); }
        export fn __addsf3(a: f32, b: f32) -> f32 { return f32_of(std::softfloat::add32(b32(a), b32(b))); }
        export fn __subsf3(a: f32, b: f32) -> f32 { return f32_of(std::softfloat::sub32(b32(a), b32(b))); }
        export fn __mulsf3(a: f32, b: f32) -> f32 { return f32_of(std::softfloat::mul32(b32(a), b32(b))); }
        export fn __divsf3(a: f32, b: f32) -> f32 { return f32_of(std::softfloat::div32(b32(a), b32(b))); }
        export fn __negsf2(a: f32) -> f32 { return f32_of(b32(a) ^ 0x80000000); }

        // comparisons, as libgcc's: <0, 0 or >0 like a - b; a NaN gives 1 to eq/ne/lt/le, -1 to
        // ge/gt, so each comparison comes out false
        public fn le64(a: f64, b: f64) -> i32 {
            val c = std::softfloat::cmp64(b64(a), b64(b));
            if (c == 2) {
                return 1;
            }
            return c;
        }
        public fn ge64(a: f64, b: f64) -> i32 {
            val c = std::softfloat::cmp64(b64(a), b64(b));
            if (c == 2) {
                return -1;
            }
            return c;
        }
        export fn __eqdf2(a: f64, b: f64) -> i32 { return le64(a, b); }
        export fn __nedf2(a: f64, b: f64) -> i32 { return le64(a, b); }
        export fn __ltdf2(a: f64, b: f64) -> i32 { return le64(a, b); }
        export fn __ledf2(a: f64, b: f64) -> i32 { return le64(a, b); }
        export fn __gedf2(a: f64, b: f64) -> i32 { return ge64(a, b); }
        export fn __gtdf2(a: f64, b: f64) -> i32 { return ge64(a, b); }
        export fn __unorddf2(a: f64, b: f64) -> i32 {
            if (std::softfloat::is_nan(b64(a)) || std::softfloat::is_nan(b64(b))) {
                return 1;
            }
            return 0;
        }
        export fn __eqsf2(a: f32, b: f32) -> i32 { return le64(__extendsfdf2(a), __extendsfdf2(b)); }
        export fn __nesf2(a: f32, b: f32) -> i32 { return le64(__extendsfdf2(a), __extendsfdf2(b)); }
        export fn __ltsf2(a: f32, b: f32) -> i32 { return le64(__extendsfdf2(a), __extendsfdf2(b)); }
        export fn __lesf2(a: f32, b: f32) -> i32 { return le64(__extendsfdf2(a), __extendsfdf2(b)); }
        export fn __gesf2(a: f32, b: f32) -> i32 { return ge64(__extendsfdf2(a), __extendsfdf2(b)); }
        export fn __gtsf2(a: f32, b: f32) -> i32 { return ge64(__extendsfdf2(a), __extendsfdf2(b)); }
        export fn __unordsf2(a: f32, b: f32) -> i32 { return __unorddf2(__extendsfdf2(a), __extendsfdf2(b)); }

        // conversions
        export fn __extendsfdf2(a: f32) -> f64 { return f64_of(std::softfloat::f32_to_f64(b32(a))); }
        export fn __truncdfsf2(a: f64) -> f32 { return f32_of(std::softfloat::f64_to_f32(b64(a))); }
        export fn __fixdfsi(a: f64) -> i32 { return std::softfloat::f64_to_i32(b64(a)); }
        export fn __fixdfdi(a: f64) -> i64 { return std::softfloat::f64_to_i64(b64(a)); }
        export fn __fixunsdfsi(a: f64) -> u32 { return std::softfloat::f64_to_u32(b64(a)); }
        export fn __fixunsdfdi(a: f64) -> u64 { return std::softfloat::f64_to_u64(b64(a)); }
        export fn __fixsfsi(a: f32) -> i32 { return __fixdfsi(__extendsfdf2(a)); }
        export fn __fixsfdi(a: f32) -> i64 { return __fixdfdi(__extendsfdf2(a)); }
        export fn __fixunssfsi(a: f32) -> u32 { return __fixunsdfsi(__extendsfdf2(a)); }
        export fn __fixunssfdi(a: f32) -> u64 { return __fixunsdfdi(__extendsfdf2(a)); }
        export fn __floatsidf(i: i32) -> f64 { return f64_of(std::softfloat::i64_to_f64(@cast<i64>(i))); }
        export fn __floatdidf(i: i64) -> f64 { return f64_of(std::softfloat::i64_to_f64(i)); }
        export fn __floatunsidf(i: u32) -> f64 { return f64_of(std::softfloat::u64_to_f64(false, @cast<u64>(i))); }
        export fn __floatundidf(i: u64) -> f64 { return f64_of(std::softfloat::u64_to_f64(false, i)); }
        export fn __floatsisf(i: i32) -> f32 { return f32_of(std::softfloat::i64_to_f32(@cast<i64>(i))); }
        export fn __floatdisf(i: i64) -> f32 { return f32_of(std::softfloat::i64_to_f32(i)); }
        export fn __floatunsisf(i: u32) -> f32 { return f32_of(std::softfloat::u64_to_f32(false, @cast<u64>(i))); }
        export fn __floatundisf(i: u64) -> f32 { return f32_of(std::softfloat::u64_to_f32(false, i)); }
    }
}
