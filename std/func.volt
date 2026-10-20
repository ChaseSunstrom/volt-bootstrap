// std::func<F>: a closure kept past its scope. A fn value only borrows its closure, so a function
// returns a closure (or code keeps one) as a std::func<fn(A) -> R>, which owns it and what it
// captured. A closure literal written where one is wanted becomes one (through from_closure, below),
// its parameters typed by F; std::func<F>::from_closure(c) makes one from a closure c. It calls, and
// passes where an F is wanted, as the fn it holds; it moves, but has no copy.

// the closure, in memory of its own, and the fn value lent from it
<F: type, C: type>
struct func_holder {
    f: F;
    c: C;
}

// @owns("ptr"): used like the F it holds; when it goes, its delete (below) deletes the closure and
// what it captured, and frees their memory
<F: type>
@attributes([@owns("ptr")])
public struct func {
    ptr: F*;                 // the fn value, lent from the closure beside it
    block: void*;            // the closure's memory (a func_holder<F, C>)
    drop: fn(void*) -> void; // deletes it: one per closure type
}

// deletes a func_holder<F, C>'s closure, then frees it
<F: type, C: type>
fn func_drop(p: void*) -> void {
    val h = @cast<std::func_holder<F, C>*>(p);
    val c = @read(&h->c); // deleted here
    var a: std::mem::default_allocator = {};
    a.free<std::func_holder<F, C>>(h);
}

// a func owning closure c: c moves to memory of its own, and the func lends an F from it. A hook, as
// delete is: a closure literal written where a std::func<F> is wanted comes here (any type holding a
// fn value through @owns can attach one)
<F: type, C: type>
public attach fn from_closure(static this: std::func<F>, c: C) -> std::func<F> {
    var a: std::mem::default_allocator = {};
    val h: std::func_holder<F, C>* = a.malloc<std::func_holder<F, C>>() catch @panic("out of memory");
    @write(&h->c, move c);
    val f: F = h->c; // lent from the closure, which stays where it is when the func moves
    @write(&h->f, f);
    val d: fn(void*) -> void = std::func_drop<F, C>;
    return { ptr: &h->f, block: @cast<void*>(h), drop: d };
}

// deletes the closure and what it captured, and frees their memory
<F: type>
public attach fn delete(this: std::func<F>&) -> void {
    val d = this.drop;
    d(this.block);
}
