// Node.js calls plainlib (voltc bindings --lang node and --lang js): the plain shapes beyond
// mathlib's
const m = require("./plainlib");

// the plain shapes: a struct with text, an array and a struct in it (in, out, in an array, from a
// callback), one with a pointer, an E!T parameter (a value, or an Error naming the error)
const ab = { name: "ab", sizes: [1, 2, 3], at: { x: 7, y: 0 } };
console.log("label", m.pl_label_len(ab));
const lo = m.pl_label_of("ab", 3);
console.log("label_of", lo.name, lo.sizes.join(" "), lo.at.x);
console.log("labels", m.pl_labels_len([ab, lo]));
console.log("holder", m.pl_holder_k({ p: null, k: 3 }));
console.log("or", m.pl_or(4.5, 9.5), m.pl_or(m.voltError(m.plain_error.NEGATIVE), 9.5));
console.log("ask", m.pl_ask((k) => ({ name: "abc", sizes: [k, k, k], at: { x: 3, y: 0 } })));
