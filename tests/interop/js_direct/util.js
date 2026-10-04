// Plain JavaScript: its types are in util.d.ts beside it
export function greet(name) {
  return `hello, ${name}`;
}

export class Counter {
  constructor(start) {
    this.n = start;
  }

  tick() {
    this.n += 1;
    return this.n;
  }
}
