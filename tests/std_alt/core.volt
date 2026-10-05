// A tiny std written from scratch: nothing in voltc knows these names. It binds compiler-provided
// functions with @intrinsic and makes its own owning pointer with @owns.
namespace out {
    @attributes([@intrinsic("println")])
    public fn say() -> void;
}

namespace heap {
    @attributes([@intrinsic("volt_rt_malloc")])
    public fn raw_alloc(size: usize) -> void*;
    @attributes([@intrinsic("volt_rt_free")])
    public fn raw_free(p: void*) -> void;

    <T: type>
    @attributes([@owns("p")])
    public struct own {
        p: T&;
    }

    <T: type>
    public fn make(value: T) -> own<T> {
        val raw = raw_alloc(@sizeof(T)) ?? @panic("out of memory");
        val p = @cast<T&>(raw);
        @write(p, move value);
        return { p: p };
    }
}

<T: type>
public attach fn delete(this: std::heap::own<T>&) -> void {
    std::heap::raw_free(this.p as void*);
}
