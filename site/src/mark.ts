// The mark: a signal trace bent into a V, and the spark at its leading end, as the header, the hero
// and the interop hub draw it (assets/logo/logo.ts writes src/assets/volt-mark.svg). Its viewBox
// is 0 22 100 56. Read at build time.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const svg = readFileSync(resolve(process.cwd(), "src/assets/volt-mark.svg"), "utf8");
export const trace = svg.match(/<path d="([^"]+)"/)![1];
export const [cx, cy, r] = ["cx", "cy", "r"].map((a) => svg.match(new RegExp(`<circle[^>]* ${a}="([^"]+)"`))![1]);
