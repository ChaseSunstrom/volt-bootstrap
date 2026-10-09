// JavaScript (Node.js or Bun) calls the Volt library through voltc bindings --lang node and --lang js:
// errors are thrown with the error's name as their code, owned text comes back as a string, an
// export struct is a class (close() frees it now; otherwise it's freed when collected)
const m = require("./mathlib");

console.log("add", m.ml_add(2, 3));
const a = { x: 1, y: 2 }, b = { x: 3, y: 4 };
console.log("dot", m.ml_dot(a, b));
m.ml_scale(a, 2);
console.log("scale", a.x, a.y);
console.log("len", m.ml_len("hello"));
console.log("clash", m.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14));
const tg = m.ml_tags_make();
const head = `tags ${tg.from} ${tg.type} ${tg.self} ${tg.int}`;
tg.int = 5;
console.log(head, m.ml_tags_sum(tg));
const bp = [7], bq = [2.5];
m.ml_bump(bp, bq);
console.log("bump", bp[0], bq[0]);
console.log("next", m.ml_next(m.color.GREEN));
console.log("sqrt", m.ml_sqrt(9), 1);
try {
    m.ml_sqrt(-1);
} catch (e) {
    console.log("error", e.code === m.math_error.NEGATIVE ? "negative" : "?");
}
console.log("greet", m.ml_greet("volt"));
console.log("repeat", m.ml_repeat("ab", 2));
try {
    m.ml_repeat("ab", -1);
} catch (e) {
    console.log("repeat", e.message.toLowerCase());
}
console.log("sum", m.ml_sum([1, 2, 3.5]));
const ys = [4, 5, 6];
console.log("find", m.ml_find(ys, 6), m.ml_find(ys, 9) === null ? "none" : "?");
const seen = [];
m.ml_each(ys, (x) => seen.push(x));
console.log("each", seen.join(" "), "=", seen.reduce((s, x) => s + x, 0));
const c = new m.counter("clicks");
c.add(2);
console.log("counter", c.name(), c.add(3));
try {
    c.take(9);
} catch (e) {
    console.log("take", e.code.toLowerCase());
}
c.close();
