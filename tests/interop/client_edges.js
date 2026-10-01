// what the Node-API addon rejects: numbers that don't fit the parameter, NaN and infinities, wrong
// types, and a closed object
const m = require("./mathlib");

function attempt(what, f) {
    try {
        f();
        console.log(what, "accepted");
    } catch (e) {
        console.log(what, e.constructor.name);
    }
}

attempt("too big for i32", () => m.ml_add(5000000000, 1));
attempt("NaN", () => m.ml_add(NaN, 1));
attempt("Infinity", () => m.ml_find([Infinity], 1));
attempt("fraction for i32", () => m.ml_add(1.5, 1));
attempt("string for a number", () => m.ml_add("1", 1));
attempt("not a counter", () => m.counter.prototype.add.call({}, 1));
const c = new m.counter("x");
c.close();
attempt("closed counter", () => c.add(1));
console.log("bigint", m.ml_find([4, 5, 6], 6));
