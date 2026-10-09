// TypeScript calls the Volt library through voltc bindings --lang node, --lang js and --lang ts
// (node runs it by stripping the types; tsc checks them against mathlib.d.ts)
import { createRequire } from "node:module";
import type * as M from "./mathlib.js";

const m: typeof M = createRequire(import.meta.url)("./mathlib.js");

const a: M.vec2 = { x: 1, y: 2 };
console.log("add", m.ml_add(2, 3));
console.log("dot", m.ml_dot(a, { x: 3, y: 4 }));
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
    console.log("error", (e as M.VoltError).code === m.math_error.NEGATIVE ? "negative" : "?");
}
console.log("greet", m.ml_greet("volt"));
console.log("repeat", m.ml_repeat("ab", 2));
try {
    m.ml_repeat("ab", -1);
} catch (e) {
    console.log("repeat", (e as M.VoltError).message.toLowerCase());
}
console.log("sum", m.ml_sum([1, 2, 3.5]));
const ys: number[] = [4, 5, 6];
const found: number | null = m.ml_find(ys, 6);
console.log("find", found, m.ml_find(ys, 9) === null ? "none" : "?");
const seen: number[] = [];
m.ml_each(ys, (x: number) => {
    seen.push(x);
});
console.log("each", seen.join(" "), "=", seen.reduce((s, x) => s + x, 0));
const c: M.counter = new m.counter("clicks");
c.add(2);
console.log("counter", c.name(), c.add(3));
try {
    c.take(9);
} catch (e) {
    console.log("take", (e as M.VoltError).code.toLowerCase());
}
c.close();
// structs with text, an array and a struct in them (in, out, in an array, from a callback), one
// with a pointer, E!T as a parameter (a value, or an Error naming the error)
const la: M.ml_label = { name: "ab", sizes: [1, 2, 3], at: { x: 7, y: 0 } };
console.log("label", m.ml_label_len(la));
const lb: M.ml_label = m.ml_label_of("ab", 3);
console.log("label_of", lb.name, lb.sizes.join(" "), lb.at.x);
console.log("labels", m.ml_labels_len([la, lb]));
console.log("holder", m.ml_holder_k({ p: null, k: 3 }));
console.log("or", m.ml_or(4.5, 9.5), m.ml_or(m.voltError(m.math_error.NEGATIVE), 9.5));
console.log("ask", m.ml_ask((k: number) => ({ name: "abc", sizes: [k, k, k], at: { x: 3, y: 0 } })));
m.ml_relabel(lb, 4);
console.log("relabel", lb.name, lb.sizes.join(" "));
console.log("count", m.ml_labels_count([la, lb]));
console.log("note", m.ml_note_len({ str: "abc", c: 1, k: 3 }));
console.log("or_label", m.ml_or_label(la), m.ml_or_label(m.voltError(m.math_error.NEGATIVE)));
console.log("given", m.ml_sum_given(3, (k: number) => [k, 10 * k]), m.ml_area_given((k: number) => [{ x: 1.5, y: k }, { x: 2, y: 3.25 }]));
const deep = [[[1, 2], [3]], [[4]]];
const d = m.ml_deep(deep);
console.log("deep", d, deep[0][0][1], deep[1][0][0], "words", m.ml_words([["ab", "c"], [], ["def"]]));
