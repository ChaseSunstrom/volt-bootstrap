// The Volt logo, as code: a signal trace bent into a V, with an amber spark at its leading end (the
// mark), and a geometric lowercase "volt" drawn with round strokes (the wordmark). No tile and no
// glow: the mark stands on whatever it's on. `npm run build` writes the SVGs and PNGs here, the VS
// Code extension's icons into editors/vscode/images, and the website's mark and favicon into site/.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";

const here = dirname(fileURLToPath(import.meta.url));

// ---------- colours ----------

const colors = {
  traceDark: "#A78BFA", // the trace on dark backgrounds (violet)
  traceLight: "#6B3DF5", // ...and on light ones
  sparkDark: "#FFCF4A", // the spark (amber)
  sparkLight: "#C98500",
  night: "#0C0920", // the site's background, and the icon's tile
  inkLight: "#191338", // the wordmark on light backgrounds
  inkDark: "#F4F1FF", // ...and on dark ones
};

// ---------- the mark ----------

type Point = [number, number];

// The trace in a 100×100 box: level, down into the V, back up, level again; the spark sits just past
// its end. Drawn with round caps and joins. The small form (icons of 16-48 px, the favicon) is
// bolder, with a deeper V, so it holds at a few pixels.
const MARK = {
  trace: [[5, 32], [30, 32], [45, 68], [60, 32], [80, 32]] as Point[],
  spark: [89, 32] as Point,
  stroke: 9,
  sparkR: 7.5,
};
const MARK_SMALL = {
  trace: [[4, 30], [26, 30], [44, 72], [62, 30], [76, 30]] as Point[],
  spark: [88, 30] as Point,
  stroke: 13,
  sparkR: 10,
};

function fmt(n: number): string {
  return String(Math.round(n * 100) / 100);
}

// the trace as a path, through a mapping from the 100×100 box
function tracePath(pts: Point[], at: (p: Point) => string): string {
  return pts.map((p, i) => `${i === 0 ? "M" : "L"}${at(p)}`).join(" ");
}

// the mark with its 100×100 box at (x, y), scaled to size
function mark(x: number, y: number, size: number, trace: string, spark: string, small = false): string {
  const m = small ? MARK_SMALL : MARK;
  const k = size / 100;
  const at = (p: Point) => `${fmt(x + p[0] * k)} ${fmt(y + p[1] * k)}`;
  return `
  <path d="${tracePath(m.trace, at)}" fill="none" stroke="${trace}" stroke-width="${fmt(m.stroke * k)}" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="${fmt(x + m.spark[0] * k)}" cy="${fmt(y + m.spark[1] * k)}" r="${fmt(m.sparkR * k)}" fill="${spark}"/>`;
}

// the mark alone on a square canvas, for dark or light backgrounds
function markSvg(size: number, dark: boolean, small = false): string {
  // the mark's ink spans y 27..73 of its box: centred as is
  return svg(size, size, mark(0, 0, size, dark ? colors.traceDark : colors.traceLight, dark ? colors.sparkDark : colors.sparkLight, small));
}

// the mark on a flat night tile: for the places that want an app icon (the VS Code extension, PNGs)
function iconSvg(size: number): string {
  const small = size <= 48;
  const inset = size * (small ? 0.06 : 0.14);
  return svg(size, size, `
  <rect width="${fmt(size)}" height="${fmt(size)}" rx="${fmt(size * 0.22)}" fill="${colors.night}"/>${mark(inset, inset, size - 2 * inset, colors.traceDark, colors.sparkDark, small)}`);
}

// the favicon: the small mark, in the colours of the browser's theme
function faviconSvg(): string {
  const m = MARK_SMALL;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 100 100">
  <style>
    path { stroke: ${colors.traceLight}; }
    circle { fill: ${colors.sparkLight}; }
    @media (prefers-color-scheme: dark) {
      path { stroke: ${colors.traceDark}; }
      circle { fill: ${colors.sparkDark}; }
    }
  </style>
  <path d="${tracePath(m.trace, (p) => `${p[0]} ${p[1]}`)}" fill="none" stroke-width="${m.stroke}" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="${m.spark[0]}" cy="${m.spark[1]}" r="${m.sparkR}"/>
</svg>
`;
}

// the website's mark, cropped to its ink (the header reads its path and spark from this)
function siteMarkSvg(): string {
  const m = MARK;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="56" viewBox="0 22 100 56">
  <path d="${tracePath(m.trace, (p) => `${p[0]} ${p[1]}`)}" fill="none" stroke="${colors.traceDark}" stroke-width="${m.stroke}" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="${m.spark[0]}" cy="${m.spark[1]}" r="${m.sparkR}" fill="${colors.sparkDark}"/>
</svg>
`;
}

// ---------- the wordmark ----------

// Each letter as centre-line strokes, in units of the x-height (y down: 0 is the x-height line, 1 the
// baseline). Strokes are drawn with round caps and joins, STROKE wide.
const STROKE = 0.21;

interface Glyph {
  d: (u: (x: number, y: number) => string) => string; // the path, through a unit→canvas mapping
  left: number; // the centre line's extent
  right: number;
}

const GLYPHS: Record<string, Glyph> = {
  v: { d: (u) => `M${u(0, 0)} L${u(0.44, 1)} L${u(0.88, 0)}`, left: 0, right: 0.88 },
  o: {
    // a circle as two arcs
    d: (u) => `M${u(0, 0.5)} A${u(0.5, 0.5, true)} 0 1 0 ${u(1, 0.5)} A${u(0.5, 0.5, true)} 0 1 0 ${u(0, 0.5)} Z`,
    left: 0,
    right: 1,
  },
  l: { d: (u) => `M${u(0, -0.5)} L${u(0, 1)}`, left: 0, right: 0 },
  t: {
    d: (u) => `M${u(0, -0.32)} L${u(0, 0.72)} Q${u(0, 1)} ${u(0.3, 1)} M${u(-0.24, 0)} L${u(0.34, 0)}`,
    left: -0.24,
    right: 0.34,
  },
};

const TRACKING = 0.3; // between the ink of neighbouring letters

// "volt" with its x-height line at y and x-height h, starting at x; its paths and its width
function wordmark(x: number, y: number, h: number, ink: string): { body: string; width: number } {
  let pen = x;
  let paths = "";
  for (const ch of "volt") {
    const g = GLYPHS[ch];
    const origin = pen + (STROKE / 2 - g.left) * h;
    const u = (ux: number, uy: number, radius = false): string =>
      radius ? `${fmt(ux * h)} ${fmt(uy * h)}` : `${fmt(origin + ux * h)} ${fmt(y + uy * h)}`;
    paths += `<path d="${(g.d as (u: unknown) => string)(u)}"/>`;
    pen += (g.right - g.left + STROKE + TRACKING) * h;
  }
  const width = pen - x - TRACKING * h;
  const body = `
  <g fill="none" stroke="${ink}" stroke-width="${fmt(STROKE * h)}" stroke-linecap="round" stroke-linejoin="round">${paths}</g>`;
  return { body, width };
}

// ---------- files ----------

function svg(w: number, h: number, inner: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${fmt(w)}" height="${fmt(h)}" viewBox="0 0 ${fmt(w)} ${fmt(h)}">${inner}\n</svg>\n`;
}

// the mark and the wordmark side by side, height tall
function logoSvg(height: number, dark: boolean): string {
  const pad = height * 0.08;
  const size = height - 2 * pad;
  const ink = dark ? colors.inkDark : colors.inkLight;
  const xh = size * 0.36; // the wordmark's x-height
  // the x-height band sits on the trace's level, so the word reads as the signal's continuation
  const top = pad + size * 0.3;
  const m = mark(pad, pad, size, dark ? colors.traceDark : colors.traceLight, dark ? colors.sparkDark : colors.sparkLight);
  const w = wordmark(pad + size + size * 0.12, top, xh, ink);
  const width = pad + size + size * 0.12 + w.width + pad;
  return svg(width, height, `${m}${w.body}`);
}

function png(svgText: string, width: number): Buffer {
  return new Resvg(svgText, { fitTo: { mode: "width", value: width } }).render().asPng();
}

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
  console.log(`wrote ${path}`);
}

const light = logoSvg(200, false);
const dark = logoSvg(200, true);

write(join(here, "volt-mark-dark.svg"), markSvg(512, true));
write(join(here, "volt-mark-light.svg"), markSvg(512, false));
write(join(here, "volt-logo-light.svg"), light);
write(join(here, "volt-logo-dark.svg"), dark);
write(join(here, "favicon.svg"), faviconSvg());
for (const size of [16, 32, 48, 64, 128, 256, 512]) {
  write(join(here, `volt-icon-${size}.png`), png(iconSvg(size), size));
}
write(join(here, "volt-logo-light.png"), png(light, 1200));
write(join(here, "volt-logo-dark.png"), png(dark, 1200));

// the VS Code extension's icons: the marketplace icon, and the .volt file icon
const ext = join(here, "../../editors/vscode/images");
write(join(ext, "icon.png"), png(iconSvg(256), 256));
write(join(ext, "volt-file.svg"), svg(100, 100, mark(0, 0, 100, "#8F6BFF", colors.sparkDark, true)));

// the website's mark and favicon
write(join(here, "../../site/src/assets/volt-mark.svg"), siteMarkSvg());
write(join(here, "../../site/public/favicon.svg"), faviconSvg());
