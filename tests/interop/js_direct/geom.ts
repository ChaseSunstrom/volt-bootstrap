// Ordinary TypeScript: nothing in it is written for Volt
export const VERSION = "1.2";
export const LIMIT = 10;

export enum Color {
  Red,
  Green = 5,
  Blue,
}

export class Point {
  x: number;
  y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }

  norm(): number {
    return Math.hypot(this.x, this.y);
  }

  scale(k: number): void {
    this.x *= k;
    this.y *= k;
  }

  static origin(): Point {
    return new Point(0, 0);
  }

  toString(): string {
    return `(${this.x}, ${this.y})`;
  }
}

export class Shape {
  name: string;
  color: Color = Color.Green;
  private sides: number[];
  static made: number = 0;

  constructor(name: string, sides: number[]) {
    this.name = name;
    this.sides = [...sides];
    Shape.made++;
  }

  perimeter(): number {
    return this.sides.reduce((a, b) => a + b, 0);
  }

  add(side: number): void {
    this.sides.push(side);
  }

  get count(): number {
    return this.sides.length;
  }

  describe(prefix: string = "a"): string {
    return `${prefix} ${this.name} with ${this.count} sides`;
  }
}

export class Square extends Shape {
  constructor(side: number) {
    super("square", [side, side, side, side]);
  }

  area(): number {
    return this.perimeter() ** 2 / 16;
  }
}

export function dist(a: Point, b: Point): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

export function add(a: number, b: number = 2): number {
  return a + b;
}

export function upper(s: string): string {
  return s.toUpperCase();
}

export function total(xs: number[]): number {
  return xs.reduce((a, b) => a + b, 0);
}

// changes Volt's array: the change comes back
export function doubleAll(xs: number[]): void {
  for (let i = 0; i < xs.length; i++) xs[i] *= 2;
}

export function squares(n: number): number[] {
  return Array.from({ length: n }, (_, i) => (i + 1) ** 2);
}

export function words(s: string): string[] {
  return s.trim().split(/\s+/);
}

export function join(parts: string[], sep: string = "-"): string {
  return parts.join(sep);
}

export function find(xs: number[], x: number): number | null {
  const i = xs.indexOf(x);
  return i < 0 ? null : i;
}

export function nextColor(c: Color): Color {
  return c === Color.Red ? Color.Green : c === Color.Green ? Color.Blue : Color.Red;
}

export function longest(a: Shape, b: Shape): Shape {
  return a.perimeter() >= b.perimeter() ? a : b;
}

export function even(x: number): boolean {
  return x % 2 === 0;
}

export function maybe(name: string): Shape | null {
  return name === "" ? null : new Shape(name, [1]);
}

export function fail(msg: string): number {
  throw new Error(msg);
}

// generics: each instance a program uses converts its own type
export function first<T>(xs: T[]): T {
  return xs[0];
}

export function pair<A, B>(a: A, b: B): string {
  return `${a}/${b}`;
}

export class Box<T> {
  value: T;

  constructor(value: T) {
    this.value = value;
  }

  get(): T {
    return this.value;
  }

  set(v: T): void {
    this.value = v;
  }

  async settled(): Promise<T> {
    await null;
    return this.value;
  }
}

// async: a call gives the settled value; a rejection stops the program, as a throw does
export async function later(n: number): Promise<number> {
  await null;
  return n * 2;
}

export async function greetLater(s: string): Promise<string> {
  await Promise.resolve();
  return `later ${s}`;
}

export function soon(n: number): Promise<number> {
  return Promise.resolve(n + 1);
}

export let ticks = 0;

export async function tick(): Promise<void> {
  await null;
  ticks++;
}

export function ticked(): number {
  return ticks;
}

export async function rejectLater(msg: string): Promise<number> {
  await null;
  throw new Error(msg);
}

export async function never(): Promise<number> {
  await new Promise(() => {});
  return 0;
}

// callbacks: a Volt fn value, which JavaScript calls (and may keep)
export function apply(f: (x: number) => number, x: number): number {
  return f(x);
}

export function each(n: number, f: (i: number) => void): number {
  for (let i = 0; i < n; i++) f(i);
  return n;
}

let kept: ((s: string) => string) | null = null;

export function keep(f: (s: string) => string): void {
  kept = f;
}

export function callKept(s: string): string {
  return kept ? kept(s) : "";
}

// object types: an interface or a type alias of an object is a Volt struct, copied
export interface Size {
  w: number;
  h: number;
  tag?: number;
  label?: string;
}

export type Range = { lo: number; hi: number };

export function area(s: Size): number {
  return s.w * s.h + (s.tag ?? 0);
}

export function grow(s: Size, k: number): Size {
  return { w: s.w * k, h: s.h * k, label: s.label ? s.label + "!" : undefined };
}

export function labelOf(s: Size): string {
  return s.label ?? "none";
}

export function squareSizes(n: number): Size[] {
  const out: Size[] = [];
  for (let i = 1; i <= n; i++) out.push({ w: i, h: i });
  return out;
}

export function totalArea(xs: Size[]): number {
  return xs.reduce((t, s) => t + area(s), 0);
}

export function span(r: Range): number {
  return r.hi - r.lo;
}

// Volt can't call these: they're listed in a comment of what bolt writes
export function guess(x: number) {
  return x * 2;
}
