// TypeScript calls the Volt library greet: the same addon as JavaScript, typed by
// bindings/greet.d.ts
import { createRequire } from "node:module";
import type * as Greet from "../greet/target/debug/bindings/greet.js";

const greet: typeof Greet = createRequire(import.meta.url)("../greet/target/debug/bindings/greet.js");

console.log("add", greet.add(2, 3));
console.log(greet.hello("volt"));
const c: Greet.tally = new greet.tally("clicks");
c.add(1);
const n: number = c.add(2);
console.log(c.name(), n);
c.close();
