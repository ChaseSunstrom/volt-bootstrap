// The landing page's motion: each .reveal section gets .on once it scrolls into view, which starts
// its CSS animation (switches flipping, bars charging, current running); the code lines in the
// hero's output get their index for the line-by-line reveal. Sections only wait in their
// pre-animation state while :root has data-motion, which this sets, so with no script, or with
// reduced motion, everything is shown as it ends up.
const root = document.documentElement;
const still = matchMedia("(prefers-reduced-motion: reduce)").matches;

for (const out of document.querySelectorAll<HTMLElement>(".stage-out .out")) {
  out.querySelectorAll<HTMLElement>(".line").forEach((line, i) => line.style.setProperty("--i", String(i)));
}

// once the load sequence has run, switching backends replays only the lines
setTimeout(() => delete root.dataset.intro, 4000);

if (!still && "IntersectionObserver" in window) {
  root.dataset.motion = "";
  const seen = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("on");
          seen.unobserve(e.target);
        }
      }
    },
    { threshold: 0.3 },
  );
  document.querySelectorAll(".reveal").forEach((s) => seen.observe(s));
}
