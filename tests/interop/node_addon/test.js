// loads the Volt addon (target/debug/addon.node) and prints what it gives back
const addon = require(process.argv[2]);
console.log("add", addon.add(2, 3.5));
console.log(addon.greet("volt"), addon.greet(42));
console.log("sum", addon.sum([1, 2, 3.5]));
console.log("point", JSON.stringify(addon.point(3, 4)));
console.log("apply", addon.apply((x, s) => `${x * 2} ${s}`, 21));
try {
  addon.fails();
} catch (e) {
  console.log("thrown", e instanceof Error, e.message);
}
console.log(addon.catches(() => { throw new TypeError("js says no"); }));
console.log("kinds", addon.kinds(1, "s", true, null, undefined, {}, [], () => 0).join(" "));
