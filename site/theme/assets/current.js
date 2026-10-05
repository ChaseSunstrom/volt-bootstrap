// The landing page is one circuit. On load the hero's mark draws itself and its spark lights (CSS,
// under :root[data-intro]). From that spark a trace runs down the page's right edge and into the
// terminal at the end, and scrolling carries a spark along it: whatever it passes comes on (.on)
// (headings fill with light, the runtime's breakers switch off, benchmark bars charge, the interop
// network lights up, the first command types itself). Things wait in their starting state only
// while :root has data-motion, which this sets, so with no script, or with reduced motion,
// everything shows as it ends.
const root = document.documentElement;
const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const landing = document.querySelector(".landing");

for (const out of document.querySelectorAll(".stage-out .out")) {
  out.querySelectorAll(".line").forEach((line, i) => line.style.setProperty("--i", String(i)));
}

// once the load sequence has run, switching backends replays only the lines
setTimeout(() => delete root.dataset.intro, 6000);

const NS = "http://www.w3.org/2000/svg";
function add(tag, cls, parent) {
  const e = document.createElementNS(NS, tag);
  e.setAttribute("class", cls);
  parent.append(e);
  return e;
}
const smooth = (t) => {
  t = Math.min(1, Math.max(0, t));
  return t * t * (3 - 2 * t);
};

if (!still && "ResizeObserver" in window) {
  root.dataset.motion = "";

  const svg = add("svg", "current", landing);
  svg.setAttribute("aria-hidden", "true");
  const track = add("path", "track", svg);
  const taps = add("g", "taps", svg);
  const lit = add("path", "lit", svg);
  const tail = add("path", "tail", svg);
  const spark = add("circle", "spark", svg);
  spark.setAttribute("r", "4.5");

  let pts       = [];
  let total = 0;
  let pageTop = 0; // the landing page's top, in the document
  let start = 0; // the hero spark's height in the document
  let end = 0; // where the trace ends: the terminal's first line
  let stops                                              = [];
  let cur = 0;
  let goal = 0;
  let frame = 0;
  let last = 0;

  // the length along the trace at which it first reaches height y; a level run counts once y is
  // past it, so the spark crosses it in one go
  function lengthAt(y) {
    let len = 0;
    for (let i = 1; i < pts.length; i++) {
      const [x0, y0] = pts[i - 1];
      const [x1, y1] = pts[i];
      const seg = Math.hypot(x1 - x0, y1 - y0);
      if (y1 === y0) {
        if (y < y0 + 2) return len;
      } else if (y < y1) {
        return len + (seg * Math.max(0, y - y0)) / (y1 - y0);
      }
      len += seg;
    }
    return len;
  }

  function pointAt(len)     {
    for (let i = 1; i < pts.length; i++) {
      const [x0, y0] = pts[i - 1];
      const [x1, y1] = pts[i];
      const seg = Math.hypot(x1 - x0, y1 - y0);
      if (len <= seg) return [x0 + ((x1 - x0) * len) / seg, y0 + ((y1 - y0) * len) / seg];
      len -= seg;
    }
    return pts[pts.length - 1];
  }

  function layout() {
    const box = landing.getBoundingClientRect();
    pageTop = box.top + scrollY;
    const w = landing.clientWidth;
    const h = landing.scrollHeight;
    svg.setAttribute("width", String(w));
    svg.setAttribute("height", String(h));
    svg.setAttribute("viewBox", `0 0 ${w} ${h}`);

    // the trace leaves the mark's spark, runs out to the right margin, down it, and into the terminal
    const hero = landing.querySelector(".hero");
    const right = w - parseFloat(getComputedStyle(hero).paddingRight);
    const rail = right + Math.min(32, (w - right) / 2);
    const mark = landing.querySelector(".hero-mark");
    const m = mark.getBoundingClientRect();
    const dot = mark.querySelector("circle.spark");
    const k = m.width / 100; // the mark's viewBox is 0 22 100 56
    const sx = m.left - box.left + (+dot.getAttribute("cx")  + +dot.getAttribute("r")) * k;
    const sy = m.top - box.top + (+dot.getAttribute("cy")  - 22) * k;
    const shell = landing.querySelector(".shell").getBoundingClientRect();
    const ex = shell.right - box.left;
    const ey = shell.top - box.top + 30;
    const c = Math.min(14, (rail - sx) / 2);
    pts = [[sx, sy], [rail - c, sy], [rail, sy + c], [rail, ey - c], [rail - c, ey], [ex, ey]];
    start = sy;
    end = ey;
    const d = "M" + pts.map((p) => p.map((n) => n.toFixed(1)).join(" ")).join(" L");
    for (const p of [track, lit, tail]) p.setAttribute("d", d);
    total = pts.slice(1).reduce((n, p, i) => n + Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]), 0);

    // what the spark turns on as it passes; each breaker gets a tap off the trace
    taps.replaceChildren();
    stops = [];
    for (const el of landing.querySelectorAll(".charge, .breakers li, .chart-row, .network, .shell")) {
      const r = el.getBoundingClientRect();
      const y = Math.min(r.top - box.top + Math.min(r.height / 2, 48), ey);
      let tap;
      if (el.matches(".breakers li")) {
        tap = add("g", el.classList.contains("on") ? "tap lit" : "tap", taps);
        const line = add("line", "", tap);
        line.setAttribute("x1", String(rail));
        line.setAttribute("x2", String(r.right - box.left));
        line.setAttribute("y1", String(y));
        line.setAttribute("y2", String(y));
        const j = add("circle", "", tap);
        j.setAttribute("cx", String(rail));
        j.setAttribute("cy", String(y));
        j.setAttribute("r", "3.5");
      }
      if (!el.classList.contains("on")) stops.push({ el, y, tap });
    }
    stops.sort((a, b) => a.y - b.y);
    aim();
    cur = Math.min(cur, total);
    draw();
  }

  // where the spark should be: on the mark at the top of the page, then a little below the middle
  // of the window as it scrolls, and at the trace's end by the bottom of the page
  function aim() {
    const vh = innerHeight;
    const s = scrollY;
    const from = start + pageTop;
    let v = from + (0.6 * vh - from) * smooth(s / (0.6 * vh));
    const most = root.scrollHeight - vh;
    const atEnd = end + pageTop + 4 - most;
    // over the last window's worth of scrolling, or all of it on a page that's barely taller than the window
    if (atEnd > v) v += (atEnd - v) * smooth(1 - (most - s) / Math.max(1, Math.min(vh, most)));
    goal = lengthAt(s - pageTop + v);
  }

  function draw() {
    lit.style.strokeDasharray = `${cur} ${total + 1}`;
    const t = Math.min(cur, 90);
    tail.style.strokeDasharray = `0 ${cur - t} ${t} ${total + 1}`;
    const [x, y] = pointAt(cur);
    spark.setAttribute("cx", x.toFixed(1));
    spark.setAttribute("cy", y.toFixed(1));
    spark.style.opacity = cur > 3 ? "1" : "0";
    while (stops.length && stops[0].y <= y + 1) {
      const s = stops.shift();
      s.el.classList.add("on");
      s.tap?.classList.add("lit");
    }
  }

  function tick(t) {
    const dt = last ? Math.min(64, t - last) : 16;
    last = t;
    cur += (goal - cur) * (1 - Math.exp(-dt / 110));
    if (Math.abs(goal - cur) < 0.5) cur = goal;
    draw();
    frame = cur === goal ? 0 : requestAnimationFrame(tick);
    if (!frame) last = 0;
  }

  function kick() {
    aim();
    if (!frame) frame = requestAnimationFrame(tick);
  }

  // laid out now, so a scroll the browser restores before the first resize callback has a trace to ride
  layout();
  new ResizeObserver(() => {
    layout();
    kick();
  }).observe(landing);
  addEventListener("scroll", kick, { passive: true });
}
