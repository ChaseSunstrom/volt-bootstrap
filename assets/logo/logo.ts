// The Volt logo, as code: a rounded lightning bolt on an indigo tile (the mark) and a geometric
// lowercase "volt" drawn with round strokes (the wordmark). `npm run build` writes the SVGs and PNGs
// here, the VS Code extension's icons into editors/vscode/images, and the website's bolt into site/.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";

const here = dirname(fileURLToPath(import.meta.url));

// ---------- colours ----------

const colors = {
  tileTop: "#312E81", // indigo
  tileBottom: "#0F172A", // near-black slate
  boltTop: "#FDE047", // electric yellow
  boltBottom: "#F59E0B", // amber
  glow: "#FBBF24",
  inkLight: "#111827", // the wordmark on light backgrounds
  inkDark: "#F9FAFB", // ...and on dark ones
};

// ---------- the bolt ----------

type Point = [number, number];

// A lightning bolt in a 100×100 box, symmetric about its centre: top, the left point, the notch,
// the bottom tip, the right point, the other notch
const BOLT: Point[] = [
  [60, 3],
  [15, 57],
  [46, 57],
  [40, 97],
  [85, 43],
  [54, 43],
];

// radius of each corner's rounding (the tips a little sharper)
const BOLT_RADII = [2.5, 4, 3, 2.5, 4, 3];

// a closed path through pts with each corner rounded: the corner is cut r along both edges and
// joined by a quadratic curve through the corner point
function roundedPath(pts: Point[], radii: number[], scale: number, [dx, dy]: Point): string {
  const p = (q: Point): string => `${fmt(dx + q[0] * scale)} ${fmt(dy + q[1] * scale)}`;
  const toward = (a: Point, b: Point, r: number): Point => {
    const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    const t = Math.min(r / len, 0.5);
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
  };
  let d = "";
  pts.forEach((cur, i) => {
    const prev = pts[(i + pts.length - 1) % pts.length];
    const next = pts[(i + 1) % pts.length];
    const a = toward(cur, prev, radii[i]);
    const b = toward(cur, next, radii[i]);
    d += `${i === 0 ? "M" : "L"}${p(a)} Q${p(cur)} ${p(b)} `;
  });
  return d + "Z";
}

function fmt(n: number): string {
  return String(Math.round(n * 100) / 100);
}

// ---------- the mark ----------

// the mark at (x, y), size×size: the tile, a soft glow and the bolt. small (16-48 px icons, the
// favicon): a bigger bolt and no glow, which only blurs at that size
function mark(x: number, y: number, size: number, small = false): { defs: string; body: string } {
  const ids = "m";
  const boltSize = size * (small ? 0.78 : 0.66);
  const at: Point = [x + (size - boltSize) / 2, y + (size - boltSize) / 2];
  const bolt = roundedPath(BOLT, BOLT_RADII, boltSize / 100, at);
  const defs = `
    <linearGradient id="${ids}-tile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${colors.tileTop}"/>
      <stop offset="1" stop-color="${colors.tileBottom}"/>
    </linearGradient>
    <radialGradient id="${ids}-shine" cx="0.25" cy="0.15" r="0.9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="0.6" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="${ids}-bolt" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${colors.boltTop}"/>
      <stop offset="1" stop-color="${colors.boltBottom}"/>
    </linearGradient>
    <filter id="${ids}-glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="${fmt(size * 0.035)}"/>
    </filter>`;
  const r = fmt(size * 0.225);
  const edge = size * 0.012; // a faint rim, so the tile holds on dark backgrounds
  const body = `
  <rect x="${fmt(x)}" y="${fmt(y)}" width="${fmt(size)}" height="${fmt(size)}" rx="${r}" fill="url(#${ids}-tile)"/>
  <rect x="${fmt(x + edge / 2)}" y="${fmt(y + edge / 2)}" width="${fmt(size - edge)}" height="${fmt(size - edge)}" rx="${r}" fill="url(#${ids}-shine)" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="${fmt(edge)}"/>${small ? "" : `
  <path d="${bolt}" fill="${colors.glow}" opacity="0.55" filter="url(#${ids}-glow)"/>`}
  <path d="${bolt}" fill="url(#${ids}-bolt)"/>`;
  return { defs, body };
}

// the bolt alone, filling size×size (the file icon)
function boltOnly(size: number): string {
  const d = roundedPath(BOLT, BOLT_RADII, size / 100, [0, 0]);
  return svg(size, size, `
  <defs>
    <linearGradient id="b" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${colors.boltTop}"/>
      <stop offset="1" stop-color="${colors.boltBottom}"/>
    </linearGradient>
  </defs>
  <path d="${d}" fill="url(#b)"/>`);
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

function markSvg(size: number, small = false): string {
  const m = mark(0, 0, size, small);
  return svg(size, size, `\n  <defs>${m.defs}\n  </defs>${m.body}`);
}

// the mark and the wordmark side by side, height tall
function logoSvg(height: number, ink: string): string {
  const pad = height * 0.08;
  const size = height - 2 * pad;
  const m = mark(pad, pad, size);
  const xh = size * 0.42; // the wordmark's x-height
  // the x-height band sits a little below the mark's centre, where lowercase looks centred
  const top = pad + size / 2 - xh * 0.38;
  const w = wordmark(pad + size + size * 0.24, top, xh, ink);
  const width = pad + size + size * 0.24 + w.width + pad;
  return svg(width, height, `\n  <defs>${m.defs}\n  </defs>${m.body}${w.body}`);
}

function png(svgText: string, width: number): Buffer {
  return new Resvg(svgText, { fitTo: { mode: "width", value: width } }).render().asPng();
}

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
  console.log(`wrote ${path}`);
}

const markText = markSvg(512);
const light = logoSvg(200, colors.inkLight);
const dark = logoSvg(200, colors.inkDark);

write(join(here, "volt-mark.svg"), markText);
write(join(here, "volt-bolt.svg"), boltOnly(100));
write(join(here, "volt-logo-light.svg"), light);
write(join(here, "volt-logo-dark.svg"), dark);
write(join(here, "favicon.svg"), markSvg(64, true));
for (const size of [16, 32, 48, 64, 128, 256, 512]) {
  write(join(here, `volt-mark-${size}.png`), png(size <= 48 ? markSvg(size, true) : markText, size));
}
write(join(here, "volt-logo-light.png"), png(light, 1200));
write(join(here, "volt-logo-dark.png"), png(dark, 1200));

// the VS Code extension's icons
const ext = join(here, "../../editors/vscode/images");
write(join(ext, "icon.png"), png(markText, 256));
write(join(ext, "volt-file.svg"), boltOnly(100));

// the website's bolt (the site draws its own mark and favicon, in the board's colours)
write(join(here, "../../site/src/assets/volt-bolt.svg"), boltOnly(100));
