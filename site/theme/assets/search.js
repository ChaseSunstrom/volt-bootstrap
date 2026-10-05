// The site's search, in place of Pagefind: site/gen writes search.json (each page's sections: URL,
// title and text), read on first use. The dialog behaves as Starlight's (the button, Ctrl/Cmd+K,
// Escape, a click outside), and results use Pagefind's markup, so the theme's styles for it apply.
const base = "/volt-bootstrap/";
let index = null;

function load() {
  if (!index) {
    index = fetch(base + "search.json").then((r) => r.json());
  }
  return index;
}

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// twelve words around the first match, as Pagefind cuts them, each word with a match marked
function excerpt(text, words) {
  const all = text.split(/\s+/).filter((w) => w.length > 0);
  const hit = (w) => words.some((q) => w.toLowerCase().includes(q));
  const first = Math.max(0, all.findIndex(hit));
  const start = Math.max(0, Math.min(first - 6, all.length - 12));
  return all
    .slice(start, start + 12)
    .map((w) => (hit(w) ? `<mark>${esc(w)}</mark>` : esc(w)))
    .join(" ");
}

// every word in the title or text; titles count most, then how often the words appear
function score(section, words) {
  const title = section.t.toLowerCase();
  const text = section.x.toLowerCase();
  let s = 0;
  for (const w of words) {
    const inTitle = title.includes(w);
    const count = text.split(w).length - 1;
    if (!inTitle && count === 0) return 0;
    s += (inTitle ? 10 : 0) + Math.min(count, 5);
  }
  return s;
}

function search(pages, query) {
  const words = query.toLowerCase().split(/\s+/).filter((w) => w.length > 0);
  if (words.length === 0) return [];
  const hits = [];
  for (const p of pages) {
    const subs = p.s.slice(1).map((s) => ({ s, score: score(s, words) })).filter((h) => h.score > 0);
    const top = score({ t: p.t, x: p.s.map((s) => s.x).join(" ") }, words);
    if (top === 0 && subs.length === 0) continue;
    subs.sort((a, b) => b.score - a.score);
    hits.push({ page: p, score: top + (subs[0]?.score ?? 0), subs: subs.slice(0, 3), words });
  }
  hits.sort((a, b) => b.score - a.score);
  return hits;
}

// results in Pagefind's markup, with the classes the theme's copy of its styles is scoped to: a page
// with matching sections lists up to three of them, a page without shows its own excerpt; five
// pages at a time
const UI = "svelte-e9gkc3";
const RES = "svelte-4xnkmf";

function title(url, text) {
  return `<p class="pagefind-ui__result-title ${RES}"><a class="pagefind-ui__result-link ${RES}" href="${esc(url)}">${esc(text)}</a></p>`;
}

function result(h) {
  const top = h.page.s[0];
  const subs = h.subs.filter((x) => x.s !== top);
  let inner = title(h.page.u, h.page.t);
  if (subs.length === 0) {
    const text = h.words.some((w) => top.x.toLowerCase().includes(w)) ? top.x : h.page.s.map((s) => s.x).join(" ");
    inner += `<p class="pagefind-ui__result-excerpt ${RES}">${excerpt(text, h.words)}</p>`;
  }
  for (const x of subs) {
    inner += `<div class="pagefind-ui__result-nested ${RES}">${title(x.s.u, x.s.t)}<p class="pagefind-ui__result-excerpt ${RES}">${excerpt(x.s.x, h.words)}</p></div>`;
  }
  return `<li class="pagefind-ui__result ${RES}"><div class="pagefind-ui__result-inner ${RES}">${inner}</div></li>`;
}

function render(root, query, hits, shown) {
  const drawer = root.querySelector(".pagefind-ui__drawer");
  drawer.classList.toggle("pagefind-ui__hidden", !query.trim());
  if (!query.trim()) {
    drawer.innerHTML = "";
    return;
  }
  const message = hits.length === 0 ? `No results for ${esc(query)}` : `${hits.length} result${hits.length === 1 ? "" : "s"} for ${esc(query)}`;
  const more = hits.length > shown ? `<button type="button" class="pagefind-ui__button ${UI}">Load more results</button>` : "";
  drawer.innerHTML = `<div class="pagefind-ui__results-area ${UI}"><p class="pagefind-ui__message ${UI}">${message}</p><ol class="pagefind-ui__results ${UI}">${hits.slice(0, shown).map(result).join("")}</ol>${more}</div>`;
}

class SiteSearch extends HTMLElement {
  constructor() {
    super();
    const openBtn = this.querySelector("button[data-open-modal]");
    const closeBtn = this.querySelector("button[data-close-modal]");
    const dialog = this.querySelector("dialog");
    const dialogFrame = this.querySelector(".dialog-frame");
    const root = this.querySelector("#starlight__search");

    // close on a link, or a click outside the dialog's frame
    const onClick = (event) => {
      const isLink = "href" in (event.target || {});
      if (isLink || (document.body.contains(event.target) && !dialogFrame.contains(event.target))) {
        closeModal();
      }
    };
    const openModal = (event) => {
      dialog.showModal();
      document.body.toggleAttribute("data-search-modal-open", true);
      this.querySelector("input")?.focus();
      event?.stopPropagation();
      window.addEventListener("click", onClick);
    };
    const closeModal = () => dialog.close();

    openBtn.addEventListener("click", openModal);
    openBtn.disabled = false;
    closeBtn.addEventListener("click", closeModal);
    dialog.addEventListener("close", () => {
      document.body.toggleAttribute("data-search-modal-open", false);
      window.removeEventListener("click", onClick);
    });
    window.addEventListener("keydown", (e) => {
      if ((e.metaKey === true || e.ctrlKey === true) && e.key === "k") {
        dialog.open ? closeModal() : openModal();
        e.preventDefault();
      }
    });

    let placeholder = "Search";
    try {
      placeholder = JSON.parse(this.dataset.translations || "{}").placeholder || placeholder;
    } catch {}
    root.innerHTML = `<div class="pagefind-ui ${UI} pagefind-ui--reset"><form class="pagefind-ui__form ${UI}" role="search" aria-label="Search this site" action="javascript:void(0);"><input class="pagefind-ui__search-input ${UI}" type="text" placeholder="${esc(placeholder)}" title="${esc(placeholder)}" autocapitalize="none" enterkeyhint="search" style="padding-right: 50px;"> <button class="pagefind-ui__search-clear ${UI} pagefind-ui__suppressed">Clear</button> <div class="pagefind-ui__drawer ${UI} pagefind-ui__hidden"></div></form></div>`;
    const input = root.querySelector("input");
    const clear = root.querySelector(".pagefind-ui__search-clear");
    let hits = [];
    let shown = 5;
    root.querySelector("form").addEventListener("submit", (e) => e.preventDefault());
    const run = async () => {
      clear.classList.toggle("pagefind-ui__suppressed", input.value.length === 0);
      const pages = await load();
      hits = search(pages, input.value);
      shown = 5;
      render(root, input.value, hits, shown);
    };
    input.addEventListener("input", run);
    input.addEventListener("focus", load, { once: true });
    clear.addEventListener("click", (e) => {
      e.preventDefault();
      input.value = "";
      run();
      input.focus();
    });
    root.addEventListener("click", (e) => {
      if (e.target.classList?.contains("pagefind-ui__button")) {
        shown += 5;
        render(root, input.value, hits, shown);
      }
    });
  }
}
customElements.define("site-search", SiteSearch);
