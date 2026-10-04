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

// Volt can't call these: they're listed in a comment of what bolt writes
export function apply(f: (x: number) => number, x: number): number {
  return f(x);
}

export async function later(): Promise<number> {
  return 1;
}

export function guess(x: number) {
  return x * 2;
}
