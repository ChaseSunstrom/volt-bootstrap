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

    // what box and vec allocate through; a failed malloc or realloc returns OUT_OF_MEMORY
    trait t_allocator {
        // count = number of T's
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*);
        // resize ptr's memory to count T's (it may move)
        <T: type> fn realloc(this, ptr: T*, count: usize) -> mem_error!(T*);
        // give ptr's memory back
        <T: type> fn free(this, ptr: T*) -> void;
    }

    // malloc, realloc and free from the C library. Empty, so a box using it is just a pointer
    struct default_allocator;

    attach t_allocator -> default_allocator {
        <T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*) {
            val raw = c_malloc(count * @sizeof(T)) ?? return mem_error::OUT_OF_MEMORY;
            return @cast<T*>(raw);
        }
        <T: type> fn realloc(this, ptr: T*, count: usize) -> mem_error!(T*) {
            val raw = c_realloc(ptr as void*, count * @sizeof(T)) ?? return mem_error::OUT_OF_MEMORY;
            return @cast<T*>(raw);
        }
        <T: type> fn free(this, ptr: T*) -> void {
            c_free(ptr as void*);
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
