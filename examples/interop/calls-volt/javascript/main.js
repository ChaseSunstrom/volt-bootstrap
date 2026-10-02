// JavaScript calls the Volt library greet through its Node-API addon (bindings/greet.js loads
// greet.node): owned text comes back as a string, an export struct is a class (close() frees it)
const greet = require("../greet/target/debug/bindings/greet.js");

console.log("add", greet.add(2, 3));
console.log(greet.hello("volt"));
const c = new greet.tally("clicks");
c.add(1);
const n = c.add(2);
console.log(c.name(), n);
c.close();
