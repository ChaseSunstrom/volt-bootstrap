use std::io;

struct buffer {
    name: str;
    data: std::vec<u8>;             // owned: deleted with the buffer
}

// runs when a buffer's owner goes out of scope; never called by hand
attach fn delete(this: buffer&) -> void {
    std::println("freeing {}", this.name);
}

// `copy x` calls this: deep copies are explicit
attach fn copy(this: buffer&) -> buffer {
    return { name: "copy", data: copy this.data };
}

fn fill(var b: buffer) -> buffer {  // takes ownership, gives it back
    b.data.push(7) catch @panic("out of memory");
    return b;
}

fn main() -> void {
    val a: buffer = { name: "a", data: {} };
    val b = fill(a);                // `a` moved: using it now is a compile error
    val c = copy b;                 // a deep copy: a second owner
    std::println("{} {}", b.data.len, c.data.len);
}                                   // c, then b: deleted in reverse order
// expect: 1 1
// expect: freeing copy
// expect: freeing a
